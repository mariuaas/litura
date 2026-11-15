// JavaScript: regex versus division, template strings, ASI, classes. Ünïcode ✓
'use strict';
import { readFile } from 'fs/promises';

const ratio = total / count / 2;
const pattern = /ab+c\/[0-9]{2,}/gi;
let a = b
/hi/g.exec(c)
const greeting = `hello ${user.name ?? 'anon'} — ${`nested ${1 + 2}`}`;

class Queue extends Array {
  #size = 0;
  static from(items) { return new Queue(...items); }
  get size() { return this.#size; }
  push(...values) {
    this.#size += values.length;
    return super.push(...values);
  }
}

async function* lines(path) {
  const text = await readFile(path, 'utf8');
  for (const line of text.split(/\r?\n/)) yield line;
}

const pick = ({ a, b: [first, ...rest] = [] }, ...others) => first?.[a] ?? rest.length;
label: for (let i = 0; i < 10; i++) {
  if (i % 3 === 0) continue label;
  else if (i > 7) break label;
}

export default {
  ratio, pattern, greeting,
  run() {
    return pick({ a: 'x', b: [{ x: 1 }] }) || void 0
  },
};
