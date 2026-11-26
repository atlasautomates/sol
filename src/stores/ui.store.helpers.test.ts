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

test("volume: cups, spoons, fluid ounces, gallons and litres", () => {
	converts([
		["2 cups to ml", "2 cup = 473.176 ml"],
		["1 cup to tbsp", "1 cup = 16 tbsp"],
		["1 tbsp to tsp", "1 tbsp = 3 tsp"],
		["1 tablespoon to ml", "1 tbsp = 14.7868 ml"],
		["2 teaspoons to ml", "2 tsp = 9.85784 ml"],
		["8 fl oz to ml", "8 fl oz = 236.588 ml"],
		["8 floz to ml", "8 fl oz = 236.588 ml"],
		["1 gallon to litres", "1 gal = 3.78541 l"],
		["1 gal to l", "1 gal = 3.78541 l"],
		["1 liter to ml", "1 l = 1000 ml"],
		["1 l to cups", "1 l = 4.22675 cup"],
	]);
});

test("speed: mph, km/h, m/s and knots", () => {
	converts([
		["60 mph to kmh", "60 mph = 96.5606 km/h"],
		["100 km/h to mph", "100 km/h = 62.1371 mph"],
		["100 kph to mph", "100 km/h = 62.1371 mph"],
		["10 m/s to km/h", "10 m/s = 36 km/h"],
		["1 knot to km/h", "1 knot = 1.852 km/h"],
		["20 knots to mph", "20 knot = 23.0156 mph"],
	]);
});

test("area: square feet and metres, acres and hectares", () => {
	// Exactly 46.4515 and 0.809371: convert-units counts 10.7639 sq ft to the
	// square metre, and six significant digits show that.
	converts([
		["500 sqft to m2", "500 ft² = 46.4516 m²"],
		["500 sq ft to m2", "500 ft² = 46.4516 m²"],
		["500 ft2 to sqm", "500 ft² = 46.4516 m²"],
		["1 hectare to acres", "1 ha = 2.47105 ac"],
		["1 ha to ac", "1 ha = 2.47105 ac"],
		["2 acres to ha", "2 ac = 0.809372 ha"],
	]);
});

test("digital: lowercase or uppercase names are bytes, bits are spelled out or Mb", () => {
	converts([
		["1 gb to mb", "1 GB = 1024 MB"],
		["1 GB to MB", "1 GB = 1024 MB"],
		["1 tb to gb", "1 TB = 1024 GB"],
		["1 kb to b", "1 KB = 1024 B"],
		["1 byte to bits", "1 B = 8 bit"],
		["8 Mb to MB", "8 Mbit = 1 MB"],
		["100 mbit to mb", "100 Mbit = 12.5 MB"],
		["1 TB to B", "1 TB = 1099511627776 B"],
	]);
});

test("the names that already worked still do", () => {
	converts([
		["1 inch to cm", "1 in = 2.54 cm"],
		["10 in in cm", "10 in = 25.4 cm"],
		["3 feet to meters", "3 ft = 0.9144 m"],
		["1 lb to kg", "1 lb = 0.453592 kg"],
		["16 ounces to pounds", "16 oz = 1 lb"],
		["212 fahrenheit to celsius", "212 F = 100 C"],
		["300 k to c", "300 K = 26.85 C"],
		["90 minutes to hours", "90 min = 1.5 h"],
		["1,500 m to km", "1500 m = 1.5 km"],
	]);
});

test("queries that are not unit conversions give nothing", () => {
	converts([
		["5 m to kg", null],
		["1 m/h to km/h", null],
		["100 usd to eur", null],
		["5 cups", null],
		["cups to ml", null],
		["5 cups to", null],
		["2+2", null],
	]);
});

test("feet and inches together", () => {
	converts([
		["5'10 to cm", `5' 10" ft in = 177.8 cm`],
		[`5'10" to cm`, `5' 10" ft in = 177.8 cm`],
		[`5' 10" in cm`, `5' 10" ft in = 177.8 cm`],
		["5 ft 10 in to cm", `5' 10" ft in = 177.8 cm`],
		["5ft10in to cm", `5' 10" ft in = 177.8 cm`],
		["5 feet 10 inches to m", `5' 10" ft in = 1.778 m`],
		["6'2.5 to in", `6' 2.5" ft in = 74.5 in`],
		["5 ft 10 in in mm", `5' 10" ft in = 1778 mm`],
		["5'10 to kg", null],
	]);
});
