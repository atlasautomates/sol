import assert from "node:assert/strict";
import { test } from "node:test";
import { parseUnitConversion } from "./ui.store.helpers.ts";

// Each case is [query, "<left value> <left label> = <right value> <right label>"],
// or null when the query is not a unit conversion.
function converts(cases: Array<[string, string | null]>) {
	for (const [query, expected] of cases) {
		const result = parseUnitConversion(query);
		const actual =
			result?.kind === "comparison"
				? `${result.left.value} ${result.left.label} = ${result.right.value} ${result.right.label}`
				: result;
		assert.equal(actual, expected, `query: ${query}`);
	}
}

test("conversions show six significant digits, with no float noise", () => {
	converts([
		["5 ft to cm", "5 ft = 152.4 cm"],
		["10000 ft to m", "10000 ft = 3048 m"],
		["1 mi to km", "1 mi = 1.60934 km"],
		["100 f to c", "100 F = 37.7778 C"],
		["1 kg to g", "1 kg = 1000 g"],
		["1 mg to kg", "1 mg = 0.000001 kg"],
		["1000000 km to m", "1000000 km = 1000000000 m"],
		["0 c to f", "0 C = 32 F"],
		["-40 c to f", "-40 C = -40 F"],
	]);
});
