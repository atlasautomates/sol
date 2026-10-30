export const FILE_SEARCH_PAGE = 10;
export const FILE_SEARCH_LIMIT = 100;

export type FileSearchPage<T> = {
	results: T[];
	shown: number;
};

// One search keeps its ranked list. The panel paints `shown` of that list.
// Revealing the next page does not search again and does not reorder.
export function fileSearchPage<T>(results: readonly T[]): FileSearchPage<T> {
	return {
		results: results.slice(0, FILE_SEARCH_LIMIT),
		shown: FILE_SEARCH_PAGE,
	};
}

export function revealFileSearch<T>(page: FileSearchPage<T>): FileSearchPage<T> {
	const cap = Math.min(page.results.length, FILE_SEARCH_LIMIT);
	if (page.shown >= cap) {
		return page;
	}
	return {
		results: page.results,
		shown: Math.min(page.shown + FILE_SEARCH_PAGE, cap),
	};
}

export function visibleFiles<T>(page: FileSearchPage<T>): T[] {
	return page.results.slice(0, page.shown);
}
