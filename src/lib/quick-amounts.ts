export const QUICK_AMOUNTS = [5000, 10000, 20000, 50000, 100000] as const;

export type QuickAmount = (typeof QUICK_AMOUNTS)[number];
