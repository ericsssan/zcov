pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn subtract(a: i32, b: i32) i32 {
    return a - b;
}

pub fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

pub fn sumTo(n: i32) i32 {
    var total: i32 = 0;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        total += i; // line 17: loop body, never runs when n == 0
    }
    return total;
}

pub fn clamp(x: i32) i32 {
    if (x > 100) {
        return 100; // 24: never taken, body ends in return
    }
    return x;
}
