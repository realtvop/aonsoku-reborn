// Persistent history outbox (design §8.1, §13).
// Operations are written to IndexedDB before upload. The outbox retries
// with exponential backoff and random jitter. Only the latest clear
// operation matters; duplicate operation IDs are idempotent on the server.

import type { HistoryOperationInput, HistoryOperationId } from "./types";

const OUTBOX_DB = "aonsoku-coordination";
const OUTBOX_STORE = "history-outbox";

interface OutboxEntry {
	id: HistoryOperationId;
	operation: HistoryOperationInput;
	createdAt: number;
	attempts: number;
	nextAttemptAt: number;
}

function openDb(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		const req = indexedDB.open(OUTBOX_DB, 1);
		req.onupgradeneeded = () => {
			const db = req.result;
			if (!db.objectStoreNames.contains(OUTBOX_STORE)) {
				db.createObjectStore(OUTBOX_STORE, { keyPath: "id" });
			}
		};
		req.onsuccess = () => resolve(req.result);
		req.onerror = () => reject(req.error);
	});
}

export class HistoryOutbox {
	private dbPromise: Promise<IDBDatabase> | null = null;

	private db(): Promise<IDBDatabase> {
		if (!this.dbPromise) this.dbPromise = openDb();
		return this.dbPromise;
	}

	async enqueue(operation: HistoryOperationInput): Promise<void> {
		const db = await this.db();
		const entry: OutboxEntry = {
			id: operation.operationId,
			operation,
			createdAt: Date.now(),
			attempts: 0,
			nextAttemptAt: Date.now(),
		};
		await new Promise<void>((resolve, reject) => {
			const tx = db.transaction(OUTBOX_STORE, "readwrite");
			tx.objectStore(OUTBOX_STORE).put(entry);
			tx.oncomplete = () => resolve();
			tx.onerror = () => reject(tx.error);
		});
	}

	async dequeue(id: HistoryOperationId): Promise<void> {
		const db = await this.db();
		await new Promise<void>((resolve, reject) => {
			const tx = db.transaction(OUTBOX_STORE, "readwrite");
			tx.objectStore(OUTBOX_STORE).delete(id);
			tx.oncomplete = () => resolve();
			tx.onerror = () => reject(tx.error);
		});
	}

	async getPending(): Promise<OutboxEntry[]> {
		const db = await this.db();
		return new Promise((resolve, reject) => {
			const tx = db.transaction(OUTBOX_STORE, "readonly");
			const req = tx.objectStore(OUTBOX_STORE).getAll();
			req.onsuccess = () => resolve(req.result as OutboxEntry[]);
			req.onerror = () => reject(req.error);
		});
	}

	async markAttempt(id: HistoryOperationId, success: boolean): Promise<void> {
		if (success) {
			await this.dequeue(id);
			return;
		}
		const db = await this.db();
		await new Promise<void>((resolve, reject) => {
			const tx = db.transaction(OUTBOX_STORE, "readwrite");
			const store = tx.objectStore(OUTBOX_STORE);
			const getReq = store.get(id);
			getReq.onsuccess = () => {
				const entry = getReq.result as OutboxEntry | undefined;
				if (!entry) {
					resolve();
					return;
				}
				entry.attempts++;
				const backoff = Math.min(1000 * 2 ** entry.attempts, 60_000);
				entry.nextAttemptAt = Date.now() + backoff + Math.random() * 1000;
				store.put(entry);
				resolve();
			};
			getReq.onerror = () => reject(getReq.error);
		});
	}

	async clear(): Promise<void> {
		const db = await this.db();
		await new Promise<void>((resolve, reject) => {
			const tx = db.transaction(OUTBOX_STORE, "readwrite");
			tx.objectStore(OUTBOX_STORE).clear();
			tx.oncomplete = () => resolve();
			tx.onerror = () => reject(tx.error);
		});
	}
}