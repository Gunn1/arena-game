"""Input. Every control scheme returns the same dict of actions each frame.

Actions: left, right, up, down, jump, mine, place, item1-3 (use that slot), craft (hold to open
the crafting menu, release to craft). A mouse player also gets "mouse" (cursor in tiles); a
controller also gets "stick_aim" while the right stick is pushed.
"""
import pygame

from config import CELL, HUD_H, MOUSE_PLAYER

ACTIONS = ("left", "right", "up", "down", "jump", "mine", "place", "item1", "item2", "item3", "craft")

K = pygame
LAYOUTS = {
    # P1 with mouse: left hand on WASD, items on Q/E/R next to it, hold F to craft.
    "p1_mouse": {"left": (K.K_a,), "right": (K.K_d,), "up": (K.K_w,), "down": (K.K_s,), "jump": (K.K_w, K.K_SPACE),
                 "mine": (), "place": (), "item1": (K.K_q,), "item2": (K.K_e,), "item3": (K.K_r,),
                 "craft": (K.K_f, K.K_TAB)},
    # P1 keyboard only.
    "p1_keys": {"left": (K.K_a,), "right": (K.K_d,), "up": (K.K_w,), "down": (K.K_s,), "jump": (K.K_w, K.K_SPACE),
                "mine": (K.K_q,), "place": (K.K_e,), "item1": (K.K_1,), "item2": (K.K_2,), "item3": (K.K_3,),
                "craft": (K.K_f,)},
    # P2: IJKL to move, U/O either side of I to mine/place, items on 7/8/9 right above them, hold H to craft.
    "p2_keys": {"left": (K.K_j,), "right": (K.K_l,), "up": (K.K_i,), "down": (K.K_k,), "jump": (K.K_i,),
                "mine": (K.K_u,), "place": (K.K_o,), "item1": (K.K_7,), "item2": (K.K_8,), "item3": (K.K_9,),
                "craft": (K.K_h,)},
}
SLOT_LABELS = {"p1_mouse": ("Q", "E", "R"), "p1_keys": ("1", "2", "3"), "p2_keys": ("7", "8", "9")}
CRAFT_LABELS = {"p1_mouse": "F", "p1_keys": "F", "p2_keys": "H"}

KEY_HELP = [
    ("P1", "A/D move   W or Space jump   mouse aims   left-click mine   right-click place   Q/E/R items   hold F craft"
     if MOUSE_PLAYER == 0 else "A/D move   W or Space jump   S aim down   Q mine   E place   1/2/3 items   hold F craft"),
    ("P2", "J/L move   I jump   K aim down   U mine   O place   7/8/9 items   hold H craft"),
    ("Pad", "stick move   A jump   right stick aim   RT mine   LT place   X/Y/B items   hold RB craft"),
]


def keyboard_layouts():
    return ["p1_mouse" if MOUSE_PLAYER == 0 else "p1_keys", "p2_keys"]


class KeyboardControls:
    def __init__(self, layout_name, mouse=False):
        self.layout = LAYOUTS[layout_name]
        self.slot_labels = SLOT_LABELS[layout_name]
        self.craft_label = CRAFT_LABELS[layout_name]
        self.mouse = mouse

    def read(self, pressed):
        state = {action: any(pressed[k] for k in keys) for action, keys in self.layout.items()}
        if self.mouse:
            mx, my = pygame.mouse.get_pos()
            state["mouse"] = (mx / CELL, (my - HUD_H) / CELL)      # in tiles
            left, _, right = pygame.mouse.get_pressed()
            state["mine"] = state["mine"] or left
            state["place"] = state["place"] or right
        return state


class JoystickControls:
    """Xbox-style pad. Uses SDL's game-controller mapping when it recognises the pad, so the
    buttons are in the same place on Xbox, PlayStation and Switch pads."""
    DEAD = 0.45
    slot_labels = ("X", "Y", "B")
    craft_label = "RB"

    def __init__(self, joystick):
        self.joy = joystick
        self.pad = None
        try:
            from pygame._sdl2 import controller
            controller.init()
            index = joystick.get_id()
            if controller.is_controller(index):
                self.pad = controller.Controller(index)
        except (ImportError, pygame.error, AttributeError):
            self.pad = None

    def read(self, pressed):
        if self.pad:
            p = self.pad
            axis = lambda a: p.get_axis(a) / 32767                  # noqa: E731
            btn = lambda b: bool(p.get_button(b))                   # noqa: E731
            lx, ly = axis(pygame.CONTROLLER_AXIS_LEFTX), axis(pygame.CONTROLLER_AXIS_LEFTY)
            rx, ry = axis(pygame.CONTROLLER_AXIS_RIGHTX), axis(pygame.CONTROLLER_AXIS_RIGHTY)
            dx = btn(pygame.CONTROLLER_BUTTON_DPAD_RIGHT) - btn(pygame.CONTROLLER_BUTTON_DPAD_LEFT)
            dy = btn(pygame.CONTROLLER_BUTTON_DPAD_DOWN) - btn(pygame.CONTROLLER_BUTTON_DPAD_UP)
            state = {
                "jump": btn(pygame.CONTROLLER_BUTTON_A),
                "item1": btn(pygame.CONTROLLER_BUTTON_X),
                "item2": btn(pygame.CONTROLLER_BUTTON_Y),
                "item3": btn(pygame.CONTROLLER_BUTTON_B),
                "craft": btn(pygame.CONTROLLER_BUTTON_RIGHTSHOULDER),
                "mine": axis(pygame.CONTROLLER_AXIS_TRIGGERRIGHT) > 0.3,
                "place": axis(pygame.CONTROLLER_AXIS_TRIGGERLEFT) > 0.3,
            }
        else:
            # Unknown pad: guess the common Linux/Xbox raw layout.
            j = self.joy
            ax = lambda n: j.get_axis(n) if n < j.get_numaxes() else 0.0          # noqa: E731
            b = lambda n: n < j.get_numbuttons() and bool(j.get_button(n))        # noqa: E731
            lx, ly, rx, ry = ax(0), ax(1), ax(3), ax(4)
            dx, dy = (j.get_hat(0)[0], -j.get_hat(0)[1]) if j.get_numhats() else (0, 0)
            state = {"jump": b(0), "item3": b(1), "item1": b(2), "item2": b(3), "craft": b(5),
                     "mine": ax(5) > 0.3, "place": ax(2) > 0.3}
        if dx or dy:
            lx, ly = dx, dy
        state.update(left=lx < -self.DEAD, right=lx > self.DEAD, up=ly < -self.DEAD, down=ly > self.DEAD)
        if abs(rx) > 0.5 or abs(ry) > 0.5:
            state["stick_aim"] = (rx, ry)                           # twin-stick aiming
        return state
