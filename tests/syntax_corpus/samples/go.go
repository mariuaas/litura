// Package sample: Go with generics, closures, select and raw strings. Ünïcode ✓
package sample

import (
	"errors"
	"fmt"
	"strings"
)

type Number interface {
	~int | ~int64 | ~float64
}

type Stack[T any] struct {
	items []T
}

func (s *Stack[T]) Push(v T) { s.items = append(s.items, v) }

func (s *Stack[T]) Pop() (T, error) {
	var zero T
	if len(s.items) == 0 {
		return zero, errors.New("empty")
	}
	v := s.items[len(s.items)-1]
	s.items = s.items[:len(s.items)-1]
	return v, nil
}

func Sum[N Number](values ...N) (total N) {
	for _, v := range values {
		total += v
	}
	return
}

const raw = `a raw
string — ünïcode`

func Run(ch chan int, done <-chan struct{}) string {
	var b strings.Builder
	counter := func() func() int {
		n := 0
		return func() int { n++; return n }
	}()
	for {
		select {
		case v, ok := <-ch:
			if !ok {
				return b.String()
			}
			fmt.Fprintf(&b, "%d:%d ", v, counter())
		case <-done:
			return raw
		default:
			goto end
		}
	}
end:
	switch x := Sum(1, 2, 3); {
	case x > 5:
		return "big"
	}
	return fmt.Sprint(map[string][]int{"a": {1, 2}})
}
