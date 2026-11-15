// TSX: JSX elements inside TypeScript, generic arrows, fragments. Ünïcode ✓
import React, { useState } from 'react';

type Props<T> = { items: T[]; render: (item: T) => React.ReactNode; title?: string };

export function List<T extends { id: number }>({ items, render, title = 'Lïst' }: Props<T>) {
  const [open, setOpen] = useState<boolean>(true);
  const toggle = () => setOpen(previous => !previous);
  return (
    <section className="list" data-open={open}>
      <h2 onClick={toggle}>{title} — {items.length}</h2>
      {open && (
        <ul>
          {items.map(item => (
            <li key={item.id}>{render(item)}</li>
          ))}
        </ul>
      )}
      <>
        <input type="text" value={title} disabled />
        {items.length > 0 ? <span>{items.length / 2}</span> : null}
      </>
    </section>
  );
}

const identity = <T,>(value: T) => value;
export default List;
