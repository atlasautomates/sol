// The search bar's calculator: a small arithmetic evaluator with no
// dependencies. It reads numbers, + - * / % ^, postfix !, parentheses, the
// constants PI and E, and a fixed table of Math functions. Nothing else: no
// variables, assignment, strings or user-defined functions, so a query can
// never reach JavaScript beyond these tables.
//
// Precedence follows expr-eval, which this replaced: a function written
// without parentheses (`sqrt 16`) applies to everything up to the next
// * / % + or -, `^` binds tighter than unary minus and associates right, and
// `!` binds tighter than `^`.

const EXPRESSION_RESULT_DECIMALS = 12;

// Callable with or without parentheses: `sqrt(16)`, `sqrt 16`.
const PREFIX_FUNCTIONS: Record<string, (x: number) => number> = {
	sin: Math.sin,
	cos: Math.cos,
	tan: Math.tan,
	asin: Math.asin,
	acos: Math.acos,
	atan: Math.atan,
	sinh: Math.sinh,
	cosh: Math.cosh,
	tanh: Math.tanh,
	asinh: Math.asinh,
	acosh: Math.acosh,
	atanh: Math.atanh,
	sqrt: Math.sqrt,
	cbrt: Math.cbrt,
	log: Math.log,
	ln: Math.log,
	log2: Math.log2,
	lg: Math.log10,
	log10: Math.log10,
	expm1: Math.expm1,
	log1p: Math.log1p,
	abs: Math.abs,
	ceil: Math.ceil,
	floor: Math.floor,
	round: Math.round,
	trunc: Math.trunc,
	exp: Math.exp,
	sign: Math.sign,
};

// Callable with parentheses only: `max(1, 2)`.
const CALL_FUNCTIONS: Record<string, (...args: number[]) => number> = {
	min: Math.min,
	max: Math.max,
	hypot: Math.hypot,
	pow: Math.pow,
	atan2: Math.atan2,
	fac: factorial,
	roundTo,
};

const CONSTANTS: Record<string, number> = {
	PI: Math.PI,
	E: Math.E,
};

// The calculator answer for a search query, or null when the query is not an
// expression that evaluates to a number.
export function evaluateExpression(query: string): string | null {
	let value: number;
	try {
		value = evaluate(normalizeCalculatorQuery(query));
	} catch (_) {
		// A parse error, and also the RangeError a stack overflow throws when a
		// query nests deeper than the recursive parser can go: both show nothing.
		return null;
	}
	if (Number.isNaN(value)) {
		return null;
	}
	return formatExpressionResult(value, query);
}

export function normalizeCalculatorQuery(query: string): string {
	return query
		.replace(
			/(\d{1,3}(?:\.\d{3})+),(\d+)/g,
			(_, whole: string, fraction: string) =>
				`${whole.replace(/\./g, "")}.${fraction}`,
		)
		.replace(/(\d),(\d)/g, "$1.$2");
}

export function formatExpressionResult(value: number, query = "") {
	if (!Number.isFinite(value)) {
		return value.toString();
	}

	const scale = 10 ** EXPRESSION_RESULT_DECIMALS;
	const rounded = Math.round((value + Number.EPSILON) * scale) / scale;
	const text = rounded.toString();

	if (/\d,\d/.test(query)) {
		return text.replace(".", ",");
	}

	return text;
}

type Token =
	| { kind: "number"; value: number }
	| { kind: "name"; value: string }
	| { kind: "op"; value: string };

const NUMBER = /^(?:0x[0-9a-f]+|0b[01]+|(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)/i;
const NAME = /^[A-Za-z_$][\w$]*/;
const OPERATORS = "+-*/%^!(),";

function tokenize(input: string): Token[] {
	const tokens: Token[] = [];
	let rest = input;
	while (rest.length > 0) {
		const space = /^\s+/.exec(rest);
		if (space) {
			rest = rest.slice(space[0].length);
			continue;
		}
		const number = NUMBER.exec(rest);
		if (number) {
			tokens.push({ kind: "number", value: Number(number[0]) });
			rest = rest.slice(number[0].length);
			continue;
		}
		const name = NAME.exec(rest);
		if (name) {
			tokens.push({ kind: "name", value: name[0] });
			rest = rest.slice(name[0].length);
			continue;
		}
		if (OPERATORS.includes(rest[0])) {
			tokens.push({ kind: "op", value: rest[0] });
			rest = rest.slice(1);
			continue;
		}
		throw new Error(`unexpected character ${rest[0]}`);
	}
	return tokens;
}

function evaluate(input: string): number {
	const tokens = tokenize(input);
	let position = 0;

	const peek = () => tokens[position];
	const isOp = (token: Token | undefined, value: string) =>
		token?.kind === "op" && token.value === value;
	const acceptOp = (value: string) => {
		if (isOp(peek(), value)) {
			position += 1;
			return true;
		}
		return false;
	};
	const expectOp = (value: string) => {
		if (!acceptOp(value)) {
			throw new Error(`expected ${value}`);
		}
	};
	const isPrefixFunction = (
		token: Token | undefined,
	): token is Extract<Token, { kind: "name" }> =>
		token?.kind === "name" && Object.hasOwn(PREFIX_FUNCTIONS, token.value);

	// sum := term (("+" | "-") term)*
	function sum(): number {
		let value = term();
		for (;;) {
			if (acceptOp("+")) value += term();
			else if (acceptOp("-")) value -= term();
			else return value;
		}
	}

	// term := factor (("*" | "/" | "%") factor)*
	function term(): number {
		let value = factor();
		for (;;) {
			if (acceptOp("*")) value *= factor();
			else if (acceptOp("/")) value /= factor();
			else if (acceptOp("%")) value %= factor();
			else return value;
		}
	}

	// factor := ("+" | "-") factor | power
	function factor(): number {
		if (acceptOp("-")) return -factor();
		if (acceptOp("+")) return factor();
		return power();
	}

	// power := postfix ("^" factor)*, right-associative through factor()
	function power(): number {
		const base = postfix();
		if (acceptOp("^")) return base ** factor();
		return base;
	}

	// postfix := atom "!"*
	function postfix(): number {
		let value = atom();
		while (acceptOp("!")) value = factorial(value);
		return value;
	}

	// atom := number | constant | "(" sum ")"
	//       | prefixFunction "(" sum ")" | prefixFunction factor
	//       | callFunction "(" args ")"
	// With parentheses a prefix function binds like a call (`log2(8)^2` is 9);
	// without them it takes the whole factor that follows (`log2 8^2` is 6).
	function atom(): number {
		const token = peek();
		if (token === undefined) throw new Error("unexpected end");
		position += 1;
		if (token.kind === "number") return token.value;
		if (isPrefixFunction(token)) {
			const operand = isOp(peek(), "(") ? atom() : factor();
			return PREFIX_FUNCTIONS[token.value](operand);
		}
		if (isOp(token, "(")) {
			const value = sum();
			expectOp(")");
			return value;
		}
		if (token.kind === "name") {
			if (Object.hasOwn(CONSTANTS, token.value)) {
				return CONSTANTS[token.value];
			}
			if (Object.hasOwn(CALL_FUNCTIONS, token.value)) {
				return CALL_FUNCTIONS[token.value](...callArguments());
			}
		}
		throw new Error(`unexpected ${token.value}`);
	}

	function callArguments(): number[] {
		expectOp("(");
		const args = [sum()];
		while (acceptOp(",")) args.push(sum());
		expectOp(")");
		return args;
	}

	const value = sum();
	if (position !== tokens.length) {
		throw new Error("unexpected trailing input");
	}
	return value;
}

// n! for whole numbers; anything else is NaN, so the calculator shows nothing.
function factorial(n: number): number {
	if (!Number.isInteger(n) || n < 0) return Number.NaN;
	let result = 1;
	for (let i = 2; i <= n && Number.isFinite(result); i += 1) result *= i;
	return result;
}

// Rounds to `places` decimals (negative rounds to tens, hundreds...). Shifts
// through the exponent rather than multiplying, so 2.345 rounds to 2.35.
function roundTo(value: number, places = 0): number {
	if (!Number.isInteger(places)) return Number.NaN;
	if (places === 0) return Math.round(value);
	const shift = (x: number, by: number) => {
		const [mantissa, exponent = "0"] = x.toString().split("e");
		return Number(`${mantissa}e${Number(exponent) + by}`);
	};
	return shift(Math.round(shift(value, places)), -places);
}
