import assert from "node:assert/strict";
import { test } from "node:test";
import { evaluateExpression } from "./calculator.ts";

function answers(cases: Array<[string, string | null]>) {
	for (const [query, expected] of cases) {
		assert.equal(evaluateExpression(query), expected, `query: ${query}`);
	}
}

test("arithmetic with the usual precedence", () => {
	answers([
		["2+2", "4"],
		["12*3.5", "42"],
		["(4+5)/3", "3"],
		["10 / 4", "2.5"],
		["1 + 2 * 3 - 4 / 2", "5"],
		["((2+3)*4)^2/10", "40"],
		["10%3", "1"],
		["-3%2", "-1"],
		["7 - -2", "9"],
		["2*-3", "-6"],
		["-(2+3)", "-5"],
		["--2", "2"],
		["+3", "3"],
		["42", "42"],
	]);
});

test("powers bind tighter than unary minus and associate to the right", () => {
	answers([
		["2^10", "1024"],
		["-2^2", "-4"],
		["(-2)^2", "4"],
		["2^-1", "0.5"],
		["2^3^2", "512"],
		["2*3^2", "18"],
		["2^0.5", "1.414213562373"],
	]);
});

test("factorial is postfix and binds tighter than powers", () => {
	answers([
		["5!", "120"],
		["3!+1", "7"],
		["3!!", "720"],
		["2^3!", "64"],
		["-2!", "-2"],
	]);
});

test("functions, with or without parentheses", () => {
	answers([
		["sqrt(16)", "4"],
		["sqrt 16", "4"],
		["sqrt 16 + 1", "5"],
		["sqrt 4^2", "4"],
		["abs -3 + 1", "4"],
		["-sqrt(4)", "-2"],
		["sin 0", "0"],
		["cos(0)", "1"],
		["tan(0)", "0"],
		["abs(-3)", "3"],
		["round(2.5)", "3"],
		["floor(2.7)", "2"],
		["ceil(2.1)", "3"],
		["trunc(2.7)", "2"],
		["sign(-3)", "-1"],
		["log(100)", "4.605170185988"],
		["ln(E)", "1"],
		["log10(100)", "2"],
		["lg(100)", "2"],
		["log2(8)", "3"],
		["exp(1)", "2.718281828459"],
		["cbrt(27)", "3"],
		["min(1, 2)", "1"],
		["max(1, 2, 3)", "3"],
		["pow(2, 3)", "8"],
		["hypot(3, 4)", "5"],
		["atan2(1, 1)", "0.785398163397"],
		["roundTo(3.14159, 2)", "3.14"],
		["roundTo(2.345, 2)", "2.35"],
		["roundTo(1234.5678, -2)", "1200"],
		["roundTo(2.5)", "3"],
		["round(-2.5)", "-2"],
		["asinh(1)", "0.88137358702"],
		["log2(8)^2", "9"],
		["log2 8^2", "6"],
		["log2(8)!", "6"],
		["sin cos 0", "0.841470984808"],
		["abs -2^2", "4"],
		["2^log2 8", "8"],
		["max(1, 2)!", "2"],
		["-2^-2", "-0.25"],
		["2!^2", "4"],
		["fac(5)", "120"],
	]);
});

test("constants and number literals", () => {
	answers([
		["PI", "3.14159265359"],
		["PI*2", "6.28318530718"],
		["E", "2.718281828459"],
		["1e3", "1000"],
		["2e-3*2", "0.004"],
		[".5+1", "1.5"],
		["5.", "5"],
		["1E3", "1000"],
		["1.5e+3", "1500"],
		["0x10", "16"],
		["0b101", "5"],
		["0.1+0.2", "0.3"],
		["1/3", "0.333333333333"],
		["sin(PI)", "0"],
	]);
});

test("division by zero shows infinity; undefined results show nothing", () => {
	answers([
		["1/0", "Infinity"],
		["-1/0", "-Infinity"],
		["0/0", null],
		["sqrt(-1)", null],
		["5 % 0", null],
	]);
});

test("European decimal commas are read and echoed back", () => {
	answers([
		["1,5*2", "3"],
		["1,5+1", "2,5"],
		["1.234,5*2", "2469"],
		["1.234,5+0,25", "1234,75"],
		// A comma between digits is a decimal comma, so a function's
		// arguments need a space after the comma.
		["min(1,2)", "1,2"],
	]);
});

test("text that is not an expression returns nothing", () => {
	answers([
		["notes", null],
		["ip", null],
		["pi", null],
		["e", null],
		["", null],
		[" ", null],
		["2+", null],
		["1 2", null],
		["abc 123", null],
		["2(3)", null],
		["2PI", null],
		["sqrt(16", null],
		["sqrt()", null],
		["3.5.2", null],
		["2×3", null],
		["2**3", null],
		["sqrt", null],
		["fac 3", null],
		["SQRT(9)", null],
		["1e", null],
		["1_000", null],
		["1 < 2", null],
		["true", null],
		['"a"', null],
	]);
});

test("only arithmetic: no variables, logic, strings or random numbers", () => {
	answers([
		["x = 3", null],
		["f(x) = x * 2", null],
		["1 ? 2 : 3", null],
		["true+1", null],
		["1 and 0", null],
		['length "ab"', null],
		["if(1, 2, 3)", null],
		["random()", null],
		["[1, 2]", null],
		["gamma(5)", null],
		["2.5!", null],
		["(-1)!", null],
	]);
});
