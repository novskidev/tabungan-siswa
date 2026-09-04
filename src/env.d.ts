/// <reference path="../.astro/types.d.ts" />

declare namespace App {
  interface Locals {
    profile?: {
      id: string;
      full_name: string;
      role: 'teacher' | 'master';
      created_at: string;
    };
  }
}
