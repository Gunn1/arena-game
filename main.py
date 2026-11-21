import pygame

from config import WIDTH, HEIGHT, FPS
from game import Game


def main():
    pygame.init()
    screen = pygame.display.set_mode((WIDTH, HEIGHT))
    pygame.display.set_caption("Arena (working title)")
    clock = pygame.time.Clock()
    game = Game()
    while game.running:
        dt = min(clock.tick(FPS) / 1000, 1 / 30)     # cap dt so a lag spike can't tunnel through blocks
        game.handle_events(pygame.event.get())
        game.update(dt, pygame.key.get_pressed())
        game.draw(screen)
        pygame.display.flip()
    pygame.quit()


if __name__ == "__main__":
    main()
