import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';
import path from 'node:path';

const migrations = await readD1Migrations(path.join(__dirname, 'migrations'));

export default defineWorkersConfig({
  test: {
    setupFiles: ['./test/setup.ts'],
    poolOptions: {
      workers: {
        singleWorker: true,
        miniflare: {
          compatibilityDate: '2025-02-04',
          compatibilityFlags: ['nodejs_compat'],
          d1Databases: { DB: 'test-db' },
          r2Buckets: ['ATTACHMENTS'],
          bindings: {
            TEST_MIGRATIONS: migrations,
            FIREBASE_PROJECT_ID: 'mynote-test',
            APPLE_BUNDLE_ID: 'io.mynote.app',
            APPLE_ISSUER_ID: 'test-issuer',
            APPLE_KEY_ID: 'test-key',
            APPLE_ENVIRONMENT: 'Sandbox',
            GOOGLE_PACKAGE_NAME: 'io.mynote.app',
            GOOGLE_SA_EMAIL: 'test@example.com',
            FREE_STORAGE_BYTES: '0',
            PAID_STORAGE_BYTES: '1073741824',
          },
        },
      },
    },
  },
});
