"""A Python module: indentation, decorators, f-strings, comprehensions. Ünïcode ✓"""
import os
from dataclasses import dataclass, field


def decorate(fn):
    def wrapper(*args, **kwargs):
        return fn(*args, **kwargs)
    return wrapper


@dataclass
class Point:
    x: int = 0
    y: int = 0
    tags: list[str] = field(default_factory=list)

    @property
    def norm(self) -> float:
        return (self.x ** 2 + self.y ** 2) ** 0.5

    def describe(self, prefix="pt"):
        if self.x > 0:
            label = f"{prefix}: {self.x!r}, {self.y:>4} ñ"
        elif self.x == 0:
            label = "origin"
        else:
            label = """multi
line"""
        return label


@decorate
def walk(root, depth=0):
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        try:
            if os.path.isdir(path):
                yield from walk(path, depth + 1)
            else:
                yield depth, name
        except PermissionError as error:
            print(error)
            continue
        finally:
            pass


squares = {n: n * n for n in range(10) if n % 2 == 0}
match squares:
    case {0: zero, **rest}:
        print(zero, len(rest))
    case _:
        pass

lambda_sum = lambda a, b=1: a + b
async def fetch(session, url):
    async with session.get(url) as response:
        return await response.text()
