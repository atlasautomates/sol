// Unit conversion for the search query: `5 ft to cm`, `2 cups to ml`.
//
// One table holds every unit: how it shows, the names it answers to, and its
// factor to its measure's base unit. The factors are exact by definition
// (1 in = 0.0254 m, 1 lb = 0.45359237 kg, 1 US gal = 3.785411784 l), except
// a month and a year, which are average lengths (30.4375 and 365.25 days).
// So a result has no error to hide beyond float noise.

import {
	AMOUNT,
	CONVERSION_SEPARATOR,
	formatConvertedValue,
	MAX_CONVERSION_QUERY_LENGTH,
	readAmount,
	typedDigits,
} from "./conversion.ts";
import type { TemporaryResult } from "./temporaryResult.ts";

type Measure =
	| "angle"
	| "area"
	| "count"
	| "digital"
	| "energy"
	| "length"
	| "mass"
	| "power"
	| "pressure"
	| "speed"
	| "temperature"
	| "time"
	| "volume";

type Unit = {
	// As the result shows it. The panel shows labels in capitals.
	label: string;
	measure: Measure;
	// Base units in one of this unit: metres, kilograms, litres, square
	// metres, m/s, seconds, bytes, joules, watts, pascals, radians, items.
	factor: number;
	// Temperature only: base kelvin = (value + offset) * factor.
	offset?: number;
	// Names matched lowercase, with spaces removed: `fl oz` is `floz`.
	names: string[];
	// Names matched exactly, before lowercasing, where case decides the unit.
	casedNames?: string[];
};

const INCH = 0.0254;
const FOOT = 0.3048;
const YARD = 0.9144;
const MILE = 1609.344;
const POUND = 0.45359237;
const US_GALLON = 3.785411784;
const US_FLUID_OUNCE = US_GALLON / 128;
const DAY = 86_400;

// Square or cubic forms of a length unit: sqft, ft2, ft², square feet.
function powerNames(names: string[], power: 2 | 3) {
	const symbol = power === 2 ? "²" : "³";
	const word = power === 2 ? "square" : "cubic";
	const short = power === 2 ? "sq" : "cu";
	return names.flatMap((name, index) =>
		index === 0
			? [`${short}${name}`, `${name}${power}`, `${name}${symbol}`]
			: [`${word}${name}`, `${short}${name}`],
	);
}

function area(label: string, side: number, names: string[]): Unit {
	return {
		label: `${label}²`,
		measure: "area",
		factor: side * side,
		names: powerNames([label, ...names], 2),
	};
}

function plural(...singulars: string[]) {
	return singulars.flatMap((name) => [name, `${name}s`]);
}

const UNITS: Unit[] = [
	// Length, in metres.
	{
		label: "mm",
		measure: "length",
		factor: 0.001,
		names: ["mm", ...plural("millimeter", "millimetre")],
	},
	{
		label: "cm",
		measure: "length",
		factor: 0.01,
		names: ["cm", ...plural("centimeter", "centimetre")],
	},
	{
		label: "m",
		measure: "length",
		factor: 1,
		names: ["m", ...plural("meter", "metre")],
	},
	{
		label: "km",
		measure: "length",
		factor: 1000,
		names: ["km", ...plural("kilometer", "kilometre")],
	},
	{
		// Mm is megametres: the case keeps it apart from mm.
		label: "Mm",
		measure: "length",
		factor: 1e6,
		names: plural("megameter", "megametre"),
		casedNames: ["Mm"],
	},
	{
		label: "in",
		measure: "length",
		factor: INCH,
		names: ["in", "inch", "inches"],
	},
	{
		label: "ft",
		measure: "length",
		factor: FOOT,
		names: ["ft", "foot", "feet"],
	},
	{
		label: "yd",
		measure: "length",
		factor: YARD,
		names: ["yd", ...plural("yard")],
	},
	{
		label: "mi",
		measure: "length",
		factor: MILE,
		names: ["mi", ...plural("mile")],
	},
	{
		label: "nmi",
		measure: "length",
		factor: 1852,
		names: ["nmi", ...plural("nauticalmile")],
	},

	// Mass, in kilograms. A ton is metric, as on macOS.
	{
		label: "mcg",
		measure: "mass",
		factor: 1e-9,
		names: ["mcg", "µg", "μg", ...plural("microgram")],
	},
	{
		label: "mg",
		measure: "mass",
		factor: 1e-6,
		names: ["mg", ...plural("milligram")],
	},
	{
		label: "g",
		measure: "mass",
		factor: 0.001,
		names: ["g", ...plural("gram", "gramme")],
	},
	{
		label: "kg",
		measure: "mass",
		factor: 1,
		names: ["kg", ...plural("kilogram", "kilo")],
	},
	{
		label: "t",
		measure: "mass",
		factor: 1000,
		names: ["t", "mt", ...plural("ton", "tonne", "metricton")],
	},
	{
		label: "short ton",
		measure: "mass",
		factor: 2000 * POUND,
		names: plural("shortton", "uston"),
	},
	{
		label: "oz",
		measure: "mass",
		factor: POUND / 16,
		names: ["oz", ...plural("ounce")],
	},
	{
		label: "lb",
		measure: "mass",
		factor: POUND,
		names: ["lb", "lbs", ...plural("pound")],
	},
	{
		label: "st",
		measure: "mass",
		factor: 14 * POUND,
		names: ["st", "stone", "stones"],
	},

	// Volume, in litres. Cups, pints, quarts and gallons are US measures.
	{
		label: "ml",
		measure: "volume",
		factor: 0.001,
		names: ["ml", ...plural("milliliter", "millilitre")],
	},
	{
		label: "cl",
		measure: "volume",
		factor: 0.01,
		names: ["cl", ...plural("centiliter", "centilitre")],
	},
	{
		label: "dl",
		measure: "volume",
		factor: 0.1,
		names: ["dl", ...plural("deciliter", "decilitre")],
	},
	{
		label: "l",
		measure: "volume",
		factor: 1,
		names: ["l", ...plural("liter", "litre")],
	},
	{
		label: "kl",
		measure: "volume",
		factor: 1000,
		names: ["kl", ...plural("kiloliter", "kilolitre")],
	},
	{
		label: "mm³",
		measure: "volume",
		factor: 1e-6,
		names: powerNames(["mm", "millimeter", "millimeters"], 3),
	},
	{
		label: "cm³",
		measure: "volume",
		factor: 0.001,
		names: ["cc", ...powerNames(["cm", "centimeter", "centimeters"], 3)],
	},
	{
		label: "m³",
		measure: "volume",
		factor: 1000,
		names: powerNames(["m", "meter", "meters", "metre", "metres"], 3),
	},
	{
		label: "in³",
		measure: "volume",
		factor: INCH ** 3 * 1000,
		names: powerNames(["in", "inch", "inches"], 3),
	},
	{
		label: "ft³",
		measure: "volume",
		factor: FOOT ** 3 * 1000,
		names: powerNames(["ft", "foot", "feet"], 3),
	},
	{
		label: "yd³",
		measure: "volume",
		factor: YARD ** 3 * 1000,
		names: powerNames(["yd", "yard", "yards"], 3),
	},
	{
		label: "tsp",
		measure: "volume",
		factor: US_FLUID_OUNCE / 6,
		names: ["tsp", ...plural("teaspoon")],
	},
	{
		label: "tbsp",
		measure: "volume",
		factor: US_FLUID_OUNCE / 2,
		names: ["tbsp", "tbs", ...plural("tablespoon")],
	},
	{
		label: "fl oz",
		measure: "volume",
		factor: US_FLUID_OUNCE,
		names: ["floz", "fl-oz", "fl.oz", ...plural("fluidounce")],
	},
	{
		label: "cup",
		measure: "volume",
		factor: US_GALLON / 16,
		names: plural("cup"),
	},
	{
		label: "pt",
		measure: "volume",
		factor: US_GALLON / 8,
		names: ["pt", "pnt", ...plural("pint")],
	},
	{
		label: "qt",
		measure: "volume",
		factor: US_GALLON / 4,
		names: ["qt", ...plural("quart")],
	},
	{
		label: "gal",
		measure: "volume",
		factor: US_GALLON,
		names: ["gal", ...plural("gallon")],
	},

	// Area, in square metres.
	area("mm", 0.001, ["millimeter", "millimeters", "millimetre", "millimetres"]),
	area("cm", 0.01, ["centimeter", "centimeters", "centimetre", "centimetres"]),
	area("m", 1, ["meter", "meters", "metre", "metres"]),
	area("km", 1000, ["kilometer", "kilometers", "kilometre", "kilometres"]),
	area("in", INCH, ["inch", "inches"]),
	area("ft", FOOT, ["foot", "feet"]),
	area("yd", YARD, ["yard", "yards"]),
	area("mi", MILE, ["mile", "miles"]),
	{
		label: "ha",
		measure: "area",
		factor: 10_000,
		names: ["ha", ...plural("hectare")],
	},
	{
		label: "ac",
		measure: "area",
		factor: 4840 * YARD * YARD,
		names: ["ac", ...plural("acre")],
	},

	// Speed, in metres per second. m/h is not a name: it reads as metres per
	// hour, but other converters take it for mph.
	{
		label: "m/s",
		measure: "speed",
		factor: 1,
		names: ["m/s", "mps", "meterspersecond", "metrespersecond"],
	},
	{
		label: "km/h",
		measure: "speed",
		factor: 1000 / 3600,
		names: [
			"km/h",
			"kmh",
			"kph",
			"kmph",
			"km/hr",
			"kilometersperhour",
			"kilometresperhour",
		],
	},
	{
		label: "mph",
		measure: "speed",
		factor: MILE / 3600,
		names: ["mph", "mi/h", "milesperhour"],
	},
	{
		label: "knot",
		measure: "speed",
		factor: 1852 / 3600,
		names: ["kn", "kt", "kts", ...plural("knot")],
	},
	{
		label: "ft/s",
		measure: "speed",
		factor: FOOT,
		names: ["ft/s", "fps", "feetpersecond"],
	},

	// Time, in seconds. A month and a year are their average lengths.
	{
		label: "ns",
		measure: "time",
		factor: 1e-9,
		names: ["ns", ...plural("nanosecond")],
	},
	{
		label: "ms",
		measure: "time",
		factor: 0.001,
		names: ["ms", ...plural("millisecond")],
	},
	{
		label: "s",
		measure: "time",
		factor: 1,
		names: ["s", ...plural("sec", "second")],
	},
	{
		label: "min",
		measure: "time",
		factor: 60,
		names: plural("min", "minute"),
	},
	{
		label: "h",
		measure: "time",
		factor: 3600,
		names: ["h", ...plural("hr", "hour")],
	},
	{ label: "d", measure: "time", factor: DAY, names: ["d", ...plural("day")] },
	{
		label: "week",
		measure: "time",
		factor: 7 * DAY,
		names: plural("wk", "week"),
	},
	{
		label: "month",
		measure: "time",
		factor: (365.25 / 12) * DAY,
		names: plural("month"),
	},
	{
		label: "year",
		measure: "time",
		factor: 365.25 * DAY,
		names: plural("yr", "year"),
	},

	// Digital, in bytes. Decimal as on macOS (1 GB = 1000 MB); KiB to TiB are
	// binary. A name typed in one case is bytes, as people write them
	// (1 gb to mb); bits are spelled out, or written Kb, Mb, Gb, Tb.
	{ label: "bit", measure: "digital", factor: 1 / 8, names: plural("bit") },
	{
		label: "Kbit",
		measure: "digital",
		factor: 1e3 / 8,
		names: plural("kbit", "kilobit"),
		casedNames: ["Kb"],
	},
	{
		label: "Mbit",
		measure: "digital",
		factor: 1e6 / 8,
		names: plural("mbit", "megabit"),
		casedNames: ["Mb"],
	},
	{
		label: "Gbit",
		measure: "digital",
		factor: 1e9 / 8,
		names: plural("gbit", "gigabit"),
		casedNames: ["Gb"],
	},
	{
		label: "Tbit",
		measure: "digital",
		factor: 1e12 / 8,
		names: plural("tbit", "terabit"),
		casedNames: ["Tb"],
	},
	{
		label: "B",
		measure: "digital",
		factor: 1,
		names: ["b", ...plural("byte")],
	},
	{
		label: "KB",
		measure: "digital",
		factor: 1e3,
		names: ["kb", ...plural("kilobyte")],
	},
	{
		label: "MB",
		measure: "digital",
		factor: 1e6,
		names: ["mb", ...plural("megabyte")],
	},
	{
		label: "GB",
		measure: "digital",
		factor: 1e9,
		names: ["gb", ...plural("gigabyte")],
	},
	{
		label: "TB",
		measure: "digital",
		factor: 1e12,
		names: ["tb", ...plural("terabyte")],
	},
	{
		label: "KiB",
		measure: "digital",
		factor: 2 ** 10,
		names: ["kib", ...plural("kibibyte")],
	},
	{
		label: "MiB",
		measure: "digital",
		factor: 2 ** 20,
		names: ["mib", ...plural("mebibyte")],
	},
	{
		label: "GiB",
		measure: "digital",
		factor: 2 ** 30,
		names: ["gib", ...plural("gibibyte")],
	},
	{
		label: "TiB",
		measure: "digital",
		factor: 2 ** 40,
		names: ["tib", ...plural("tebibyte")],
	},

	// Energy, in joules. A calorie is the small calorie; food Calories are kcal.
	{
		label: "J",
		measure: "energy",
		factor: 1,
		names: ["j", ...plural("joule")],
	},
	{
		label: "kJ",
		measure: "energy",
		factor: 1000,
		names: ["kj", ...plural("kilojoule")],
	},
	{
		label: "cal",
		measure: "energy",
		factor: 4.184,
		names: ["cal", "calorie", "calories"],
	},
	{
		label: "kcal",
		measure: "energy",
		factor: 4184,
		names: ["kcal", ...plural("kilocalorie")],
	},
	{
		label: "Wh",
		measure: "energy",
		factor: 3600,
		names: ["wh", ...plural("watthour")],
	},
	{
		label: "kWh",
		measure: "energy",
		factor: 3.6e6,
		names: ["kwh", ...plural("kilowatthour")],
	},

	// Power, in watts. Horsepower is mechanical.
	{ label: "W", measure: "power", factor: 1, names: ["w", ...plural("watt")] },
	{
		label: "kW",
		measure: "power",
		factor: 1000,
		names: ["kw", ...plural("kilowatt")],
	},
	{
		label: "hp",
		measure: "power",
		// 550 foot-pounds-force per second.
		factor: 550 * FOOT * POUND * 9.80665,
		names: ["hp", "horsepower"],
	},

	// Pressure, in pascals.
	{
		label: "Pa",
		measure: "pressure",
		factor: 1,
		names: ["pa", ...plural("pascal")],
	},
	{
		label: "hPa",
		measure: "pressure",
		factor: 100,
		names: ["hpa", ...plural("hectopascal")],
	},
	{
		label: "kPa",
		measure: "pressure",
		factor: 1000,
		names: ["kpa", ...plural("kilopascal")],
	},
	{
		label: "MPa",
		measure: "pressure",
		factor: 1e6,
		names: ["mpa", ...plural("megapascal")],
	},
	{
		label: "mbar",
		measure: "pressure",
		factor: 100,
		names: ["mbar", ...plural("millibar")],
	},
	{ label: "bar", measure: "pressure", factor: 1e5, names: plural("bar") },
	{
		label: "atm",
		measure: "pressure",
		factor: 101_325,
		names: ["atm", ...plural("atmosphere")],
	},
	{
		label: "psi",
		measure: "pressure",
		factor: (POUND * 9.80665) / (INCH * INCH),
		names: ["psi"],
	},
	{
		label: "ksi",
		measure: "pressure",
		factor: (1000 * POUND * 9.80665) / (INCH * INCH),
		names: ["ksi"],
	},
	{
		label: "torr",
		measure: "pressure",
		factor: 101_325 / 760,
		names: ["torr"],
	},
	{
		label: "mmHg",
		measure: "pressure",
		// The conventional millimetre of mercury, not quite a torr.
		factor: 133.322387415,
		names: ["mmhg"],
	},

	// Temperature, in kelvin.
	{
		label: "°C",
		measure: "temperature",
		factor: 1,
		offset: 273.15,
		names: [
			"c",
			"°c",
			"℃",
			"celsius",
			"degc",
			"degreec",
			"degreesc",
			"degreecelsius",
			"degreescelsius",
		],
	},
	{
		label: "°F",
		measure: "temperature",
		factor: 5 / 9,
		offset: 459.67,
		names: [
			"f",
			"°f",
			"℉",
			"fahrenheit",
			"degf",
			"degreef",
			"degreesf",
			"degreefahrenheit",
			"degreesfahrenheit",
		],
	},
	{
		label: "K",
		measure: "temperature",
		factor: 1,
		offset: 0,
		names: ["k", ...plural("kelvin")],
	},

	// Angle, in radians.
	{
		label: "rad",
		measure: "angle",
		factor: 1,
		names: ["rad", ...plural("radian")],
	},
	{
		label: "°",
		measure: "angle",
		factor: Math.PI / 180,
		names: ["deg", "°", ...plural("degree")],
	},
	{
		label: "grad",
		measure: "angle",
		factor: Math.PI / 200,
		names: plural("grad", "gradian"),
	},
	{
		label: "arcmin",
		measure: "angle",
		factor: Math.PI / 10_800,
		names: plural("arcmin", "arcminute"),
	},
	{
		label: "arcsec",
		measure: "angle",
		factor: Math.PI / 648_000,
		names: plural("arcsec", "arcsecond"),
	},

	// Count.
	{ label: "ea", measure: "count", factor: 1, names: ["ea", "each"] },
	{
		label: "dz",
		measure: "count",
		factor: 12,
		names: ["dz", "doz", ...plural("dozen")],
	},
];

function indexUnits(key: "names" | "casedNames") {
	const index = new Map<string, Unit>();
	for (const unit of UNITS) {
		for (const name of unit[key] ?? []) {
			if (index.has(name)) {
				throw new Error(`unit name ${name} names two units`);
			}
			index.set(name, unit);
		}
	}
	return index;
}

const UNITS_BY_NAME = indexUnits("names");
const UNITS_BY_CASED_NAME = indexUnits("casedNames");

function findUnit(rawName: string): Unit | null {
	const compact = rawName.trim().replace(/\s+/g, "");
	return (
		UNITS_BY_CASED_NAME.get(compact) ??
		UNITS_BY_NAME.get(compact.toLowerCase()) ??
		null
	);
}

function toBase(value: number, unit: Unit) {
	return (value + (unit.offset ?? 0)) * unit.factor;
}

function fromBase(value: number, unit: Unit) {
	return value / unit.factor - (unit.offset ?? 0);
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
		"",
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
	const from = findUnit(rawFrom);
	const to = findUnit(rawTo);
	if (from == null || to == null || from.measure !== to.measure) {
		return null;
	}

	return {
		kind: "comparison",
		left: { label: fromLabel ?? from.label, value: amountText },
		right: {
			label: to.label,
			value: formatConvertedValue(
				fromBase(toBase(value, from), to),
				typedDigits(amountText),
			),
		},
	};
}
