import { Database } from 'bun:sqlite';
import { describe, expect, test } from 'bun:test';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { snapshot } from './lib/toastdb';

// The snapshot algorithm on plain files: the copy hook stands in for
// WpnUserService writing or checkpointing while the three files are copied
// one after another.
function scratch(): { src: string; dest: string; done: () => void } {
	const dir = mkdtempSync(join(tmpdir(), 'snn-toastdb-test-'));
	return { src: join(dir, 'live.db'), dest: join(dir, 'copy.db'), done: () => rmSync(dir, { recursive: true, force: true }) };
}

describe('notification database snapshot', () => {
	test('a quiet source is copied once, sidecars included', () => {
		const { src, dest, done } = scratch();
		try {
			writeFileSync(src, 'db-v1');
			writeFileSync(src + '-wal', 'wal-v1');
			writeFileSync(src + '-shm', 'shm');
			const copied: string[] = [];
			snapshot(src, dest, { copy: (from, to) => { copied.push(from.slice(src.length)); copyFileSync(from, to); } });
			expect(copied).toEqual(['', '-wal', '-shm']);
			expect(readFileSync(dest, 'utf8')).toBe('db-v1');
			expect(readFileSync(dest + '-wal', 'utf8')).toBe('wal-v1');
		} finally {
			done();
		}
	});

	test('a WAL that vanished between copies does not survive from the earlier attempt', () => {
		const { src, dest, done } = scratch();
		try {
			writeFileSync(src, 'db-v1');
			writeFileSync(src + '-wal', 'wal-v1');
			writeFileSync(src + '-shm', 'shm');
			let copies = 0;
			snapshot(src, dest, {
				copy(from, to) {
					copyFileSync(from, to);
					// The first attempt has the database and the WAL; then a
					// checkpoint folds the WAL into the database and deletes it.
					if (++copies === 2) {
						writeFileSync(src, 'db-v2-checkpointed');
						rmSync(src + '-wal');
						rmSync(src + '-shm');
					}
				},
			});
			expect(readFileSync(dest, 'utf8')).toBe('db-v2-checkpointed');
			expect(existsSync(dest + '-wal')).toBe(false);
			expect(existsSync(dest + '-shm')).toBe(false);
			expect(copies).toBe(3);
		} finally {
			done();
		}
	});

	test('a source that changes during every copy is an error, not the last copy', () => {
		const { src, dest, done } = scratch();
		try {
			writeFileSync(src, 'db-v1');
			writeFileSync(src + '-wal', 'wal-v1');
			let writes = 0;
			expect(() => snapshot(src, dest, {
				attempts: 3,
				copy(from, to) {
					copyFileSync(from, to);
					if (from === src + '-wal') writeFileSync(src + '-wal', `wal-v${++writes}-` + 'x'.repeat(writes));
				},
			})).toThrow(/changed during each of 3 copies/);
			expect(writes).toBe(3);
		} finally {
			done();
		}
	});

	test('with real SQLite: a checkpoint and writer close mid-copy still yields every row', () => {
		const { src, dest, done } = scratch();
		const writer = new Database(src);
		try {
			writer.exec('pragma journal_mode = wal');
			writer.exec('create table t (id integer primary key)');
			writer.exec('insert into t values (1)');
			expect(existsSync(src + '-wal')).toBe(true);
			snapshot(src, dest, {
				copy(from, to) {
					copyFileSync(from, to);
					// After the WAL is copied: a second row, then the WAL is
					// checkpointed into the database and gone with the writer.
					if (from === src + '-wal') {
						writer.exec('insert into t values (2)');
						writer.exec('pragma wal_checkpoint(truncate)');
						writer.close();
					}
				},
			});
			expect(existsSync(src + '-wal')).toBe(false);
			const copy = new Database(dest, { readonly: true });
			try {
				expect(copy.query('select id from t order by id').all()).toEqual([{ id: 1 }, { id: 2 }]);
			} finally {
				copy.close();
			}
		} finally {
			try { writer.close(); } catch {}
			done();
		}
	});
});
