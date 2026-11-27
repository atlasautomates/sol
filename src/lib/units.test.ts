import assert from "node:assert/strict";
import { test } from "node:test";
import { parseUnitConversion } from "./units.ts";

// Each case is [query, "<left value> <left label> = <right value> <right label>"],
// or null when the query is not a unit conversion.
function converts(cases: Array<[string, string | null]>) {
	for (const [query, expected] of cases) {
		const result = parseUnitConversion(query);
		const actual =
			result?.kind === "comparison"
				? [
						result.left.value,
						result.left.label,
						"=",
						result.right.value,
						result.right.label,
					]
						.filter(Boolean)
						.join(" ")
				: result;
		assert.equal(actual, expected, `query: ${query}`);
	}
}

test("conversions show up to six decimals, with no float noise and no lost digits", () => {
	converts([
		["5 ft to cm", "5 ft = 152.4 cm"],
		["10000 ft to m", "10000 ft = 3048 m"],
		["1 mi to km", "1 mi = 1.609344 km"],
		["5 KM TO MI", "5 km = 3.106856 mi"],
		["100 f to c", "100 °F = 37.777778 °C"],
		["100 F TO C", "100 °F = 37.777778 °C"],
		["1 kg to g", "1 kg = 1000 g"],
		["1 mg to kg", "1 mg = 0.000001 kg"],
		["1000000 km to m", "1000000 km = 1000000000 m"],
		["1000001 mm to km", "1000001 mm = 1.000001 km"],
		["123456789 mm to km", "123456789 mm = 123.456789 km"],
		["1.0000001 kg to g", "1.0000001 kg = 1000.0001 g"],
		["1.0000001 g to kg", "1.0000001 g = 0.0010000001 kg"],
		["0.3 cm to mm", "0.3 cm = 3 mm"],
		["0 c to f", "0 °C = 32 °F"],
	]);
});

test("volume: cups, spoons, fluid ounces, gallons and litres (US measures)", () => {
	converts([
		["2 cups to ml", "2 cups = 473.176473 ml"],
		["1 cup to tbsp", "1 cup = 16 tbsp"],
		["1 tbsp to tsp", "1 tbsp = 3 tsp"],
		["1 tablespoon to ml", "1 tbsp = 14.786765 ml"],
		["2 teaspoons to ml", "2 tsp = 9.857843 ml"],
		["4 fl oz to ml", "4 fl oz = 118.294118 ml"],
		["4 floz to ml", "4 fl oz = 118.294118 ml"],
		["1 gallon to litres", "1 gal = 3.785412 l"],
		["1 gal to l", "1 gal = 3.785412 l"],
		["1 liter to ml", "1 l = 1000 ml"],
		["1 l to cups", "1 l = 4.226753 cups"],
	]);
});

test("speed: mph, km/h, m/s and knots", () => {
	converts([
		["60 mph to kmh", "60 mph = 96.56064 km/h"],
		["100 km/h to mph", "100 km/h = 62.137119 mph"],
		["100 kph to mph", "100 km/h = 62.137119 mph"],
		["100 km/hr to mph", "100 km/h = 62.137119 mph"],
		["10 m/s to km/h", "10 m/s = 36 km/h"],
		["1 knot to km/h", "1 knot = 1.852 km/h"],
		["20 knots to mph", "20 knots = 23.015589 mph"],
	]);
});

test("area: square feet and metres, acres and hectares", () => {
	converts([
		["500 sqft to m2", "500 ft² = 46.45152 m²"],
		["500 sq ft to m2", "500 ft² = 46.45152 m²"],
		["500 ft2 to sqm", "500 ft² = 46.45152 m²"],
		["1 hectare to acres", "1 ha = 2.471054 ac"],
		["1 ha to ac", "1 ha = 2.471054 ac"],
		["2 acres to ha", "2 ac = 0.809371 ha"],
	]);
});

test("digital: decimal as on macOS, KiB to TiB binary, bits spelled out or Mb", () => {
	converts([
		["1 gb to mb", "1 GB = 1000 MB"],
		["1 GB to MB", "1 GB = 1000 MB"],
		["1 tb to gb", "1 TB = 1000 GB"],
		["1 kb to b", "1 KB = 1000 B"],
		["1 kB to B", "1 KB = 1000 B"],
		["1 TB to B", "1 TB = 1000000000000 B"],
		["1 byte to bits", "1 B = 8 bits"],
		["8 Mb to MB", "8 Mbit = 1 MB"],
		["100 mbit to mb", "100 Mbit = 12.5 MB"],
		["1 GiB to MiB", "1 GiB = 1024 MiB"],
		["1 gib to mb", "1 GiB = 1073.741824 MB"],
		["1 tib to gb", "1 TiB = 1099.511628 GB"],
		["1 kib to b", "1 KiB = 1024 B"],
	]);
});

test("mass: tonnes, short tons and stone", () => {
	converts([
		["1 t to kg", "1 t = 1000 kg"],
		["1 ton to kg", "1 t = 1000 kg"],
		["2 tonnes to kg", "2 t = 2000 kg"],
		["1 short ton to lb", "1 short ton = 2000 lb"],
		["1 us ton to kg", "1 short ton = 907.18474 kg"],
		["10 stone to kg", "10 st = 63.502932 kg"],
		["1 st to lb", "1 st = 14 lb"],
	]);
});

test("temperature: degree signs and words", () => {
	converts([
		["100 °C to °F", "100 °C = 212 °F"],
		["100°c to f", "100 °C = 212 °F"],
		["20 degrees c to f", "20 °C = 68 °F"],
		["68 degrees fahrenheit to celsius", "68 °F = 20 °C"],
		["212 fahrenheit to celsius", "212 °F = 100 °C"],
		["300 k to c", "300 K = 26.85 °C"],
		["-40 c to f", "-40 °C = -40 °F"],
	]);
});

test("energy, power and pressure", () => {
	converts([
		["1 kcal to kj", "1 kcal = 4.184 kJ"],
		["100 cal to j", "100 cal = 418.4 J"],
		["1 kwh to j", "1 kWh = 3600000 J"],
		["1 kWh to Wh", "1 kWh = 1000 Wh"],
		["1000 J to kJ", "1000 J = 1 kJ"],
		["1 hp to w", "1 hp = 745.699872 W"],
		["1 kw to hp", "1 kW = 1.341022 hp"],
		["100 w to kw", "100 W = 0.1 kW"],
		["1 atm to kpa", "1 atm = 101.325 kPa"],
		["1013 hpa to atm", "1013 hPa = 0.999753 atm"],
		["1 bar to mbar", "1 bar = 1000 mbar"],
		["1 kpa to pa", "1 kPa = 1000 Pa"],
		["30 psi to kpa", "30 psi = 206.842719 kPa"],
	]);
});

test("time: hours, minutes and seconds, short or long", () => {
	converts([
		["2 hrs to mins", "2 h = 120 min"],
		["1 hr to sec", "1 h = 3600 s"],
		["90 secs to min", "90 s = 1.5 min"],
		["90 minutes to hours", "90 min = 1.5 h"],
		["1 week to days", "1 week = 7 d"],
	]);
});

test("the names that already worked still do", () => {
	converts([
		["1 inch to cm", "1 in = 2.54 cm"],
		["10 in in cm", "10 in = 25.4 cm"],
		["3 feet to meters", "3 ft = 0.9144 m"],
		["1 lb to kg", "1 lb = 0.453592 kg"],
		["1 kg to lbs", "1 kg = 2.204623 lb"],
		["16 ounces to pounds", "16 oz = 1 lb"],
		["1,500 m to km", "1,500 m = 1.5 km"],
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
		["1 kg to kJ", null],
		["1 h to km", null],
	]);
});

test("feet and inches together", () => {
	converts([
		["5'10 to cm", `5' 10" = 177.8 cm`],
		[`5'10" to cm`, `5' 10" = 177.8 cm`],
		[`5' 10" in cm`, `5' 10" = 177.8 cm`],
		["5 ft 10 in to cm", `5' 10" = 177.8 cm`],
		["5ft10in to cm", `5' 10" = 177.8 cm`],
		["5 feet 10 inches to m", `5' 10" = 1.778 m`],
		["6'2.5 to in", `6' 2.5" = 74.5 in`],
		["5 ft 10 in in mm", `5' 10" = 1778 mm`],
		["5'10 to kg", null],
	]);
});

test("to and in are read in any case", () => {
	converts([
		["2 KM TO M", "2 km = 2000 m"],
		["2 km To m", "2 km = 2000 m"],
		["10 IN IN CM", "10 in = 25.4 cm"],
		["5'10 TO CM", `5' 10" = 177.8 cm`],
	]);
});

test("the amount shows as typed", () => {
	converts([
		["0.000123 km to m", "0.000123 km = 0.123 m"],
		["1.50 m to cm", "1.50 m = 150 cm"],
		["0.50 kg to g", "0.50 kg = 500 g"],
		["-40 c to f", "-40 °C = -40 °F"],
		["-2.5 km to m", "-2.5 km = -2500 m"],
	]);
});

test("a decimal comma is a decimal point; a comma before three digits groups thousands", () => {
	converts([
		["1,5 km to m", "1,5 km = 1500 m"],
		["12,75 kg to g", "12,75 kg = 12750 g"],
		["1,000,000 m to km", "1,000,000 m = 1000 km"],
		["1.234,5 m to km", "1.234,5 m = 1.2345 km"],
	]);
});

test("inches in feet and inches must be under twelve", () => {
	converts([
		["5'13 to cm", null],
		["5 ft 12 in to cm", null],
		["5'11.5 to in", `5' 11.5" = 71.5 in`],
	]);
});

test("a long pasted query returns nothing, fast", () => {
	const query = `1 ${"lorem ipsum in dolor to ".repeat(8000)}`;
	assert.ok(query.length > 190_000);
	const started = performance.now();
	assert.equal(parseUnitConversion(query), null);
	assert.ok(performance.now() - started < 50, "took over 50 ms");
});

test("mmHg is its own unit beside torr", () => {
	converts([
		["1 mmhg to pa", "1 mmHg = 133.322387 Pa"],
		["760 mmHg to torr", "760 mmHg = 760.000108 torr"],
		["760 torr to atm", "760 torr = 1 atm"],
	]);
});

test("huge values round to 12 significant digits, with no float noise", () => {
	converts([
		["1.1 year to ns", "1.1 years = 34713360000000000 ns"],
		["99999999999999999999 mi to in", "99999999999999999999 mi = 6.336e+24 in"],
		["1234567890123456 m to m", "1234567890123456 m = 1234567890120000 m"],
	]);
});

test("small values are written out down to 1e-15, then in exponent form", () => {
	converts([
		["5 ns to min", "5 ns = 0.0000000000833333 min"],
		["1 mm to mi", "1 mm = 0.000000621371 mi"],
		["1 mcg to t", "1 mcg = 0.000000000001 t"],
		["1 ns to year", "1 ns = 3.16881e-17 years"],
	]);
});

test("more names: pnt, Greek mu, sq feet, and Mm as megametres", () => {
	converts([
		["1 pnt to ml", "1 pt = 473.176473 ml"],
		["1000 μg to mg", "1000 mcg = 1 mg"],
		["1000 µg to mg", "1000 mcg = 1 mg"],
		["500 sq feet to m2", "500 ft² = 46.45152 m²"],
		["1 sq foot to cm2", "1 ft² = 929.0304 cm²"],
		["1 Mm to km", "1 Mm = 1000 km"],
		["1 mm to m", "1 mm = 0.001 m"],
		["1 MM to m", "1 mm = 0.001 m"],
	]);
});

test("a word label is plural beside any number but 1; a symbol never is", () => {
	converts([
		["1 cup to ml", "1 cup = 236.588236 ml"],
		["0.5 cup to ml", "0.5 cups = 118.294118 ml"],
		["-1 year to month", "-1 year = -12 months"],
		["12 months to years", "12 months = 1 year"],
		["2 short tons to kg", "2 short tons = 1814.36948 kg"],
		["16 bits to bytes", "16 bits = 2 B"],
		["1 B to bit", "1 B = 8 bits"],
		["14 days to weeks", "14 d = 2 weeks"],
		["2 ft to in", "2 ft = 24 in"],
	]);
});
