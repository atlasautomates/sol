import { Parser } from "expr-eval";

const EXPRESSION_RESULT_DECIMALS = 12;

const parser = new Parser();

// The calculator answer for a search query, or null when the query is not an
// expression that evaluates to a number.
export function evaluateExpression(query: string): string | null {
	let value: unknown;
	try {
		value = parser.evaluate(normalizeCalculatorQuery(query));
	} catch (_) {
		return null;
	}
	if (typeof value !== "number" || Number.isNaN(value)) {
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
