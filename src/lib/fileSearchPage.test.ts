import assert from "node:assert/strict";
import { test } from "node:test";
import {
	fileSearchPage,
	revealFileSearch,
	visibleFiles,
} from "./fileSearchPage.ts";

function names(count: number): string[] {
	return Array.from({ length: count }, (_, index) => `file-${index}`);
}

test("the first paint shows at most 10 files", () => {
	const page = fileSearchPage(names(25));
	assert.equal(visibleFiles(page).length, 10);
	assert.deepEqual(visibleFiles(page), names(25).slice(0, 10));
});

test("scrolling to the bottom reveals the next 10 from the same result", () => {
	let searches = 0;
	const results = names(25);
	searches += 1;
	let page = fileSearchPage(results);
	page = revealFileSearch(page);
	assert.equal(searches, 1);
	assert.deepEqual(visibleFiles(page), results.slice(0, 20));
	page = revealFileSearch(page);
	assert.equal(searches, 1);
	assert.deepEqual(visibleFiles(page), results);
});

test("the list stops at 100", () => {
	let page = fileSearchPage(names(150));
	assert.equal(page.results.length, 100);
	for (let step = 0; step < 20; step += 1) {
		page = revealFileSearch(page);
	}
	assert.equal(visibleFiles(page).length, 100);
	assert.equal(page.shown, 100);
});

test("a new search starts again at 10", () => {
	let page = revealFileSearch(fileSearchPage(names(40)));
	assert.equal(visibleFiles(page).length, 20);
	page = fileSearchPage(names(40));
	assert.equal(visibleFiles(page).length, 10);
});

test("revealing keeps the ranked order of that one search", () => {
	const ranked = ["name.txt", "path.txt", "date.txt", "place.txt"];
	const page = revealFileSearch(fileSearchPage(ranked));
	assert.deepEqual(visibleFiles(page), ranked);
});
