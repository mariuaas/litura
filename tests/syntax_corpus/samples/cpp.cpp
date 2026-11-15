// C++: templates, raw strings, lambdas, ambiguity between declarations and expressions.
#include <vector>
#include <string>

namespace demo {

template <typename T, int N = 4>
class Ring {
public:
    explicit Ring(T fill) : data_(N, fill) {}
    T &operator[](std::size_t i) { return data_[i % N]; }
    template <typename F> void each(F &&f) const { for (auto &x : data_) f(x); }

private:
    std::vector<T> data_;
};

constexpr auto raw = R"delim(a "raw" string with )" inside — ünïcode)delim";

struct Point { int x, y; };
auto operator<=>(const Point &, const Point &) = default;

int ambiguous(int a, int b) {
    int (c) = a;        // declaration
    a < b > (c);        // expression
    Ring<int> r(0);
    r.each([&](int v) mutable { c += v; });
    auto sum = [](auto... xs) { return (xs + ... + 0); };
    return sum(1, 2, 3) + c;
}

}  // namespace demo

int main() {
    std::vector<std::vector<int>> grid{{1, 2}, {3, 4}};
    demo::Ring<std::string, 2> names("x");
    try {
        throw std::string(u8"Δ");
    } catch (const std::string &e) {
        return static_cast<int>(e.size()) + demo::ambiguous(1, 2);
    }
}
