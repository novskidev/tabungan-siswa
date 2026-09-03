/// <reference path="../.astro/types.d.ts" />

declare namespace App {
  interface Locals {
    profile?: {
      id: string;
      full_name: string;
      role: 'teacher' | 'parent';
      created_at: string;
    };
  }
}
