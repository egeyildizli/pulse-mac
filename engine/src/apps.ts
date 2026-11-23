export interface HealthTarget {
  name: string;
  url: string;
}

export interface AppDef {
  id: string;
  name: string;
  kind: "app" | "web" | "game" | "social" | "infra";
  color: string;
  stage?: "live" | "prelaunch";
  icon?: string;
  ascId?: string;
  playPackage?: string;
  rcProject?: string;
  stripe?: string;
  ga4Property?: string;
  metaAccount?: string;
  cfZone?: string;
  health?: HealthTarget[];
}

export const APPS: AppDef[] = [];

export const appById = (id: string) => APPS.find((a) => a.id === id);
