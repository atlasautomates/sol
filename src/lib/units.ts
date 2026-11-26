import convert from "convert-units";
import {
	AMOUNT,
	CONVERSION_SEPARATOR,
	formatConvertedValue,
	MAX_CONVERSION_QUERY_LENGTH,
	readAmount,
} from "./conversion.ts";
import type { TemporaryResult } from "./temporaryResult.ts";

const UNIT_ALIASES: Record<string, string> = {
	meter: "m",
	meters: "m",
	metre: "m",
	metres: "m",
	kilometer: "km",
	kilometers: "km",
	kilometre: "km",
	kilometres: "km",
	centimeter: "cm",
	centimeters: "cm",
	centimetre: "cm",
	centimetres: "cm",
	millimeter: "mm",
	millimeters: "mm",
	millimetre: "mm",
	millimetres: "mm",
	inch: "in",
	inches: "in",
	foot: "ft",
	feet: "ft",
	yard: "yd",
	yards: "yd",
	mile: "mi",
	miles: "mi",
	gram: "g",
	grams: "g",
	kilogram: "kg",
	kilograms: "kg",
	mg: "mg",
	milligram: "mg",
	milligrams: "mg",
	lb: "lb",
	lbs: "lb",
	pound: "lb",
	pounds: "lb",
	oz: "oz",
	ounce: "oz",
	ounces: "oz",
	liter: "l",
	liters: "l",
	litre: "l",
	litres: "l",
	milliliter: "ml",
	milliliters: "ml",
	millilitre: "ml",
	millilitres: "ml",
	second: "s",
	seconds: "s",
	sec: "s",
	minute: "min",
	minutes: "min",
	hour: "h",
	hours: "h",
	day: "d",
	days: "d",
	celsius: "C",
	fahrenheit: "F",
	kelvin: "K",
	cup: "cup",
	cups: "cup",
	tbsp: "Tbs",
	tbs: "Tbs",
	tablespoon: "Tbs",
	tablespoons: "Tbs",
	tsp: "tsp",
	teaspoon: "tsp",
	teaspoons: "tsp",
	floz: "fl-oz",
	"fl-oz": "fl-oz",
	fluidounce: "fl-oz",
	fluidounces: "fl-oz",
	gal: "gal",
	gallon: "gal",
	gallons: "gal",
	qt: "qt",
	quart: "qt",
	quarts: "qt",
	pt: "pnt",
	pint: "pnt",
	pints: "pnt",
	mph: "m/h",
	"mi/h": "m/h",
	kmh: "km/h",
	kph: "km/h",
	kmph: "km/h",
	"km/h": "km/h",
	"m/s": "m/s",
	mps: "m/s",
	knot: "knot",
	knots: "knot",
	kn: "knot",
	kt: "knot",
	kts: "knot",
	"ft/s": "ft/s",
	fps: "ft/s",
	sqft: "ft2",
	ft2: "ft2",
	"ft²": "ft2",
	squarefoot: "ft2",
	squarefeet: "ft2",
	sqm: "m2",
	m2: "m2",
	"m²": "m2",
	squaremeter: "m2",
	squaremeters: "m2",
	squaremetre: "m2",
	squaremetres: "m2",
	sqkm: "km2",
	"km²": "km2",
	sqmi: "mi2",
	"mi²": "mi2",
	sqin: "in2",
	"in²": "in2",
	sqyd: "yd2",
	"yd²": "yd2",
	sqcm: "cm2",
	"cm²": "cm2",
	ac: "ac",
	acre: "ac",
	acres: "ac",
	ha: "ha",
	hectare: "ha",
	hectares: "ha",
	// Digital names typed in one case are bytes, as people write them
	// (1 gb to mb). Bits are spelled out, or written Mb: see CASED_UNITS.
	b: "B",
	byte: "B",
	bytes: "B",
	kb: "KB",
	kilobyte: "KB",
	kilobytes: "KB",
	mb: "MB",
	megabyte: "MB",
	megabytes: "MB",
	gb: "GB",
	gigabyte: "GB",
	gigabytes: "GB",
	tb: "TB",
	terabyte: "TB",
	terabytes: "TB",
	bit: "b",
	bits: "b",
	kbit: "Kb",
	kbits: "Kb",
	kilobit: "Kb",
	kilobits: "Kb",
	mbit: "Mb",
	mbits: "Mb",
	megabit: "Mb",
	megabits: "Mb",
	gbit: "Gb",
	gbits: "Gb",
	gigabit: "Gb",
	gigabits: "Gb",
	tbit: "Tb",
	tbits: "Tb",
	terabit: "Tb",
	terabits: "Tb",
};

// Names whose case decides the unit, matched before UNIT_ALIASES lowercases:
// a lowercase b after an uppercase prefix is a bit (Mb), and kB is a byte.
const CASED_UNITS: Record<string, string> = {
	Kb: "Kb",
	Mb: "Mb",
	Gb: "Gb",
	Tb: "Tb",
	kB: "KB",
};

// convert-units keys that read as something else: m/h is its mph, but reads
// as metres per hour.
const REFUSED_UNITS = new Set(["m/h"]);

// How a convert-units key shows in the result. The panel shows labels in
// capitals, so bits need their own word to stay apart from bytes.
const UNIT_LABELS: Record<string, string> = {
	"m/h": "mph",
	"fl-oz": "fl oz",
	Tbs: "tbsp",
	pnt: "pt",
	b: "bit",
	Kb: "Kbit",
	Mb: "Mbit",
	Gb: "Gbit",
	Tb: "Tbit",
};

function normalizeUnit(rawUnit: string): string | null {
	const compact = rawUnit.trim().replace(/\s+/g, "");
	if (CASED_UNITS[compact]) {
		return CASED_UNITS[compact];
	}

	const normalized = compact.toLowerCase();
	if (REFUSED_UNITS.has(normalized)) {
		return null;
	}

	if (UNIT_ALIASES[normalized]) {
		return UNIT_ALIASES[normalized];
	}

	if (normalized === "c") {
		return "C";
	}

	if (normalized === "f") {
		return "F";
	}

	if (normalized === "k") {
		return "K";
	}

	return normalized;
}

function unitLabel(unit: string) {
	return (
		UNIT_LABELS[unit] ??
		unit.replace(/^([a-z]+)2$/, "$1²").replace(/^([a-z]+)3$/, "$1³")
	);
}

// Feet and inches written together: 5'10, 5' 10", 5 ft 10 in, 5 feet 10 inches.
const FEET_AND_INCHES = new RegExp(
	`^(?<feet>\\d+)\\s*(?:'|′|ft|feet|foot)\\s*(?<inches>\\d*\\.?\\d+)\\s*(?:"|″|''|in|inch|inches)?\\s+${CONVERSION_SEPARATOR}\\s+(?<to>.+)$`,
	"i",
);

// The amount, then the units. Two splits of the units cover `in` being both
// a separator and a unit: the first separator (10 in in cm) and the last
// (1 sq in in cm2). Each is one anchored match, so a long query stays linear.
const AMOUNT_AND_UNITS = new RegExp(`^(?<amount>${AMOUNT})\\s*(?<units>.+)$`);
const FIRST_SEPARATOR = new RegExp(`^(.+?) ${CONVERSION_SEPARATOR} (.+)$`, "i");
const LAST_SEPARATOR = new RegExp(`^(.+) ${CONVERSION_SEPARATOR} (.+)$`, "i");

function parseFeetAndInches(query: string): TemporaryResult | null {
	const match = query.match(FEET_AND_INCHES);
	if (!match?.groups) {
		return null;
	}

	const feet = Number.parseFloat(match.groups.feet);
	const inches = Number.parseFloat(match.groups.inches);
	if (inches >= 12) {
		return null;
	}

	return convertUnits(
		feet * 12 + inches,
		`${match.groups.feet}' ${match.groups.inches}"`,
		"in",
		match.groups.to,
		"ft in",
	);
}

export function parseUnitConversion(query: string): TemporaryResult | null {
	if (query.length > MAX_CONVERSION_QUERY_LENGTH) {
		return null;
	}

	const normalized = query.trim().replace(/\s+/g, " ");
	const feetAndInches = parseFeetAndInches(normalized);
	if (feetAndInches != null) {
		return feetAndInches;
	}

	const groups = normalized.match(AMOUNT_AND_UNITS)?.groups;
	const value = groups == null ? null : readAmount(groups.amount);
	if (groups == null || value == null) {
		return null;
	}

	for (const separator of [FIRST_SEPARATOR, LAST_SEPARATOR]) {
		const split = groups.units.match(separator);
		const result =
			split == null
				? null
				: convertUnits(value, groups.amount, split[1], split[2]);
		if (result != null) {
			return result;
		}
	}

	return null;
}

function convertUnits(
	value: number,
	amountText: string,
	rawFrom: string,
	rawTo: string,
	fromLabel?: string,
): TemporaryResult | null {
	const fromUnit = normalizeUnit(rawFrom);
	const toUnit = normalizeUnit(rawTo);
	if (fromUnit == null || toUnit == null) {
		return null;
	}

	try {
		const converted = convert(value)
			.from(fromUnit as any)
			.to(toUnit as any);
		return {
			kind: "comparison",
			left: { label: fromLabel ?? unitLabel(fromUnit), value: amountText },
			right: {
				label: unitLabel(toUnit),
				value: formatConvertedValue(converted),
			},
		};
	} catch {
		return null;
	}
}
