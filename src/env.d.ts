/// <reference path="../.astro/types.d.ts" />

declare namespace App {
  interface Locals {
    profile?: {
      id: string;
      full_name: string;
      role: 'teacher' | 'master';
      class_name: string | null;
      created_at: string;
    };
  }
}
