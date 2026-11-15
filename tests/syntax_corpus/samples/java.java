// Java: generics, records, switch expressions, lambdas, annotations. Ünïcode ✓
package demo;

import java.util.*;
import java.util.function.Function;

@FunctionalInterface
interface Transform<A, B> extends Function<A, B> {}

public sealed interface Shape permits Circle, Square {}

record Circle(double radius) implements Shape {}

record Square(double side) implements Shape {
    Square {
        if (side < 0) throw new IllegalArgumentException("négatif");
    }
}

public class Sample<T extends Comparable<? super T>> {
    private final List<T> items = new ArrayList<>();
    private static final String TEXT = """
        A text block — ünïcode
        """;

    @SafeVarargs
    public final Sample<T> add(T... values) {
        Collections.addAll(items, values);
        return this;
    }

    static double area(Shape shape) {
        return switch (shape) {
            case Circle c when c.radius() > 0 -> Math.PI * c.radius() * c.radius();
            case Circle c -> 0;
            case Square s -> s.side() * s.side();
        };
    }

    public static void main(String[] args) throws Exception {
        var sample = new Sample<Integer>().add(3, 1, 2);
        Transform<Integer, String> show = i -> "#" + i;
        sample.items.stream().sorted().map(show).forEach(System.out::println);
        int[][] grid = {{1, 2}, {3, 4}};
        label:
        for (int[] row : grid) {
            for (int v : row) {
                if (v == 3) break label;
            }
        }
        System.out.println(area(new Circle(1.5)) + TEXT.length() + (char) 'x');
    }
}
