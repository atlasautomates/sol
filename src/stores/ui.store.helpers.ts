import * as chrono from "chrono-node";
import { DateTime } from "luxon";
import type { TemporaryResult } from "../lib/temporaryResult.ts";

export type { TemporaryResult };
export { parseUnitConversion } from "../lib/units.ts";

export type BookmarkNode = {
	type: "folder" | "url";
	name: string;
	url?: string;
	children?: BookmarkNode[];
};

const TIMEZONE_ABBREVIATION_OFFSETS: Record<string, number> = {
	UTC: 0,
	GMT: 0,
	EST: -300,
	EDT: -240,
	CST: -360,
	CDT: -300,
	MST: -420,
	MDT: -360,
	PST: -480,
	PDT: -420,
	CET: 60,
	CEST: 120,
	EET: 120,
	EEST: 180,
	BST: 60,
	IST: 330,
	JST: 540,
	AEST: 600,
	AEDT: 660,
	ACST: 570,
	ACDT: 630,
	AWST: 480,
};

function offsetMinutesToUtcZone(offsetMinutes: number) {
	const sign = offsetMinutes >= 0 ? "+" : "-";
	const absoluteMinutes = Math.abs(offsetMinutes);
	const hours = Math.floor(absoluteMinutes / 60);
	const minutes = absoluteMinutes % 60;
	const paddedMinutes = minutes.toString().padStart(2, "0");
	return `UTC${sign}${hours}:${paddedMinutes}`;
}

export function createTextTemporaryResult(
	value: string,
	secondary?: string,
): TemporaryResult {
	return {
		kind: "text",
		value,
		secondary,
	};
}

function stripHtmlTags(input: string) {
	return input.replace(/<[^>]+>/g, " ");
}

function decodeHtmlEntities(input: string) {
	return input
		.replace(/&amp;/g, "&")
		.replace(/&quot;/g, '"')
		.replace(/&#39;/g, "'")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&nbsp;/g, " ");
}

export function getInitials(name: string) {
	return name
		.toLowerCase()
		.split(" ")
		.map((s) => s.charAt(0))
		.join("");
}

export function traverse(
	bookmarks: Array<{
		title: string;
		url: string;
		bookmarkFolder: null | string;
	}>,
	nodes: BookmarkNode[],
	bookmarkFolder: null | string,
) {
	for (const node of nodes) {
		if (node.type === "folder") {
			traverse(bookmarks, node.children ?? [], node.name);
		} else if (node.type === "url" && node.url) {
			bookmarks.push({ title: node.name, url: node.url, bookmarkFolder });
		}
	}
}

export function parseTimezoneConversion(query: string): TemporaryResult | null {
	const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
	if (!localZone) {
		return null;
	}

	const normalized = query.trim().replace(/\s+/g, " ");
	const match = normalized.match(
		/^(?<timeExpression>.+?)\s+(?<sourceTz>[A-Za-z]{2,5})(?:\s+to\s+(?<targetTz>[A-Za-z]{2,10}))?$/i,
	);

	if (!match?.groups) {
		return null;
	}

	const sourceTz = match.groups.sourceTz.toUpperCase();
	const timeExpression = match.groups.timeExpression.trim();
	const targetInput = match.groups.targetTz?.toUpperCase();
	const sourceOffset = TIMEZONE_ABBREVIATION_OFFSETS[sourceTz];

	if (sourceOffset == null) {
		return null;
	}

	let targetZone = localZone;
	let targetLabel: string | null = null;

	if (targetInput) {
		if (targetInput === "LOCAL") {
			targetZone = localZone;
		} else {
			const targetOffset = TIMEZONE_ABBREVIATION_OFFSETS[targetInput];
			if (targetOffset == null) {
				return null;
			}
			targetZone = offsetMinutesToUtcZone(targetOffset);
			targetLabel = targetInput;
		}
	}

	const parsedDate = chrono.parseDate(
		`${timeExpression} ${sourceTz}`,
		new Date(),
		{
			timezones: TIMEZONE_ABBREVIATION_OFFSETS,
		},
	);

	if (parsedDate == null) {
		return null;
	}

	const sourceDateTime = DateTime.fromJSDate(parsedDate).setZone(
		offsetMinutesToUtcZone(sourceOffset),
	);
	const targetDateTime = DateTime.fromJSDate(parsedDate).setZone(targetZone);

	if (!sourceDateTime.isValid || !targetDateTime.isValid) {
		return null;
	}

	if (targetLabel == null) {
		const shortName = targetDateTime.offsetNameShort;
		targetLabel =
			shortName != null && !/^(GMT|UTC)/i.test(shortName)
				? shortName
				: localZone;
	}

	return {
		kind: "comparison",
		left: {
			label: sourceTz,
			value: sourceDateTime.toFormat("ccc dd LLL HH:mm"),
		},
		right: {
			label: targetLabel,
			value: targetDateTime.toFormat("ccc dd LLL HH:mm"),
		},
	};
}

export function parseFlightIdentifier(query: string) {
	const normalized = query.trim().toUpperCase().replace(/\s+/g, "");
	if (!/^[A-Z]{2,3}\d{2,4}[A-Z]?$/.test(normalized)) {
		return null;
	}

	return normalized;
}

function extractFlightSnippetsFromHtml(html: string, engine: "ddg" | "google") {
	const rawMatches =
		engine === "ddg"
			? [...html.matchAll(/result__snippet[^>]*>([\s\S]*?)<\/a>/gi)].map(
					(m) => m[1],
				)
			: [
					...html.matchAll(
						/class="(?:VwiC3b|aCOpRe)[^"]*"[^>]*>([\s\S]*?)<\/div>/gi,
					),
				].map((m) => m[1]);

	return rawMatches
		.map((s) => decodeHtmlEntities(stripHtmlTags(s)))
		.map((s) => s.replace(/\s+/g, " ").trim())
		.filter(Boolean)
		.slice(0, 6);
}

function parseFlightTemporaryResultFromSnippets(
	flightIdentifier: string,
	snippets: string[],
): TemporaryResult | null {
	if (snippets.length === 0) {
		return null;
	}

	const merged = snippets.join(" ");
	const statusMatch = merged.match(
		/\b(on\s*time|delayed|cancelled|boarding|departed|landed|scheduled)\b/i,
	);
	const terminalMatch = merged.match(/\bterminal\s*([a-z0-9-]+)/i);
	const gateMatch = merged.match(/\bgate\s*([a-z0-9-]+)/i);
	const times = [...merged.matchAll(/\b\d{1,2}:\d{2}\s?(?:am|pm)?\b/gi)]
		.map((m) => m[0].toUpperCase())
		.slice(0, 2);

	if (!statusMatch && !terminalMatch && !gateMatch && times.length === 0) {
		return null;
	}

	return {
		kind: "flight",
		flight: flightIdentifier,
		status: statusMatch?.[1]?.toUpperCase(),
		departureTime: times[0],
		arrivalTime: times[1],
		terminal: terminalMatch?.[1]?.toUpperCase(),
		gate: gateMatch?.[1]?.toUpperCase(),
	};
}

const SEARCH_PAGE_TIMEOUT_MS = 6000;
const SEARCH_PAGE_USER_AGENT =
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

// GET a search results page as text. Rejects on a non-2xx status or after
// SEARCH_PAGE_TIMEOUT_MS, as the axios call it replaced did.
async function fetchSearchPage(
	url: string,
	params: Record<string, string>,
): Promise<string> {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), SEARCH_PAGE_TIMEOUT_MS);
	try {
		const response = await fetch(`${url}?${new URLSearchParams(params)}`, {
			headers: { "User-Agent": SEARCH_PAGE_USER_AGENT },
			signal: controller.signal,
		});
		if (!response.ok) {
			throw new Error(`${url} answered ${response.status}`);
		}
		return await response.text();
	} finally {
		clearTimeout(timer);
	}
}

export async function fetchFlightInfoFromWeb(
	flightIdentifier: string,
): Promise<TemporaryResult | null> {
	const searchQuery = `${flightIdentifier} flight status gate terminal departure time`;

	let ddgError: unknown;
	try {
		const ddgHtml = await fetchSearchPage("https://duckduckgo.com/html/", {
			q: searchQuery,
		});
		const ddgResult = parseFlightTemporaryResultFromSnippets(
			flightIdentifier,
			extractFlightSnippetsFromHtml(ddgHtml, "ddg"),
		);
		if (ddgResult != null) {
			return ddgResult;
		}
	} catch (error) {
		ddgError = error;
	}

	let googleError: unknown;
	try {
		const googleHtml = await fetchSearchPage("https://www.google.com/search", {
			q: searchQuery,
			hl: "en",
		});
		const googleResult = parseFlightTemporaryResultFromSnippets(
			flightIdentifier,
			extractFlightSnippetsFromHtml(googleHtml, "google"),
		);
		if (googleResult != null) {
			return googleResult;
		}
	} catch (error) {
		googleError = error;
	}

	if (googleError != null) {
		throw googleError;
	}

	if (ddgError != null) {
		throw ddgError;
	}

	return null;
}

export function formatTemporaryResultForClipboard(result: TemporaryResult) {
	if (result.kind === "text") {
		return result.secondary
			? `${result.value} (${result.secondary})`
			: result.value;
	}

	if (result.kind === "comparison") {
		const footer = result.footer ? ` | ${result.footer}` : "";
		return `${result.left.value} ${result.left.label} = ${result.right.value} ${result.right.label}${footer}`;
	}

	const parts: string[] = [];
	if (result.status) {
		parts.push(`Status: ${result.status}`);
	}
	if (result.departureTime) {
		parts.push(`Departure: ${result.departureTime}`);
	}
	if (result.arrivalTime) {
		parts.push(`Arrival: ${result.arrivalTime}`);
	}
	if (result.terminal) {
		parts.push(`Terminal: ${result.terminal}`);
	}
	if (result.gate) {
		parts.push(`Gate: ${result.gate}`);
	}

	const details = parts.join(" | ");
	return details ? `${result.flight} | ${details}` : result.flight;
}
