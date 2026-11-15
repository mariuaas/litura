// TypeScript: generics, conditional types, overloads, decorators. Ünïcode ✓
type Maybe<T> = T | null | undefined;
type ElementOf<T> = T extends readonly (infer U)[] ? U : never;
type Mapped<T> = { readonly [K in keyof T as `get${Capitalize<string & K>}`]: () => T[K] };

interface Shape {
  kind: 'circle' | 'square';
  area(): number;
}

enum Direction { Up = 1, Down, Left = 'left' }

function parse(value: string): number;
function parse(value: number): string;
function parse(value: string | number): string | number {
  return typeof value === 'string' ? Number(value) : String(value);
}

abstract class Base<T extends object = {}> implements Shape {
  kind = 'circle' as const;
  constructor(protected readonly config: T, private name?: string) {}
  abstract area(): number;
}

class Circle extends Base<{ radius: number }> {
  area() { return Math.PI * this.config.radius ** 2; }
}

const generic = <T,>(x: T): Maybe<T> => x;
const ratio = width < height ? width / height : 1;
let cast = <unknown>value as string;
namespace Outer.Inner { export const é = 1; }
declare module 'virtual' { export function f(): void; }
export { Circle, parse };
