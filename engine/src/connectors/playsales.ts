import { inflateRawSync } from "node:zlib";
import { APPS } from "../apps";
import type { Env } from "../env";
import { markSource } from "../sources";
import { addDays, fxToUsd, toUsd } from "../util";
import { googleToken } from "./ga4";

export const PLAY_FEE = 0.15;

export function unzipFirst(buf: Uint8Array): Uint8Array | null {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65_557); i--) {
    if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) return null;
  const cd = dv.getUint32(eocd + 16, true);
  if (dv.getUint32(cd, true) !== 0x02014b50) return null;
  const method = dv.getUint16(cd + 10, true);
  const csize = dv.getUint32(cd + 20, true);
  const local = dv.getUint32(cd + 42, true);
  const nameLen = dv.getUint16(local + 26, true), extraLen = dv.getUint16(local + 28, true);
  const start = local + 30 + nameLen + extraLen;
  const data = buf.subarray(start, start + csize);
  if (method === 0) return data;
  if (method === 8) return new Uint8Array(inflateRawSync(data));
  return null;
}

export function parseCsv(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let row: string[] = [], cur = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"' && text[i + 1] === '"') { cur += '"'; i++; }
      else if (c === '"') q = false;
      else cur += c;
    } else if (c === '"') q = true;
    else if (c === ",") { row.push(cur); cur = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(cur); rows.push(row); row = []; cur = "";
    } else cur += c;
  }
  if (cur || row.length) { row.push(cur); rows.push(row); }
  const head = (rows.shift() ?? []).map((h) => h.replace(/^﻿/, "").trim());
  return rows.filter((r) => r.length > 1).map((r) => Object.fromEntries(head.map((h, i) => [h, (r[i] ?? "").trim()])));
}

const ym = (d: Date) => `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
const num = (s: string | undefined) => Number((s ?? "").replace(/,/g, "")) || 0;

export function aggregatePlaySales(rows: Record<string, string>[], rates: Record<string, number>) {
  const out = new Map<string, Map<string, number>>();
  let lastDay = "";
  for (const r of rows) {
    const day = (r["Order Charged Date"] ?? "").slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
    if (day > lastDay) lastDay = day;
    const pkg = r["Product ID"];
    if (!pkg) continue;
    const status = (r["Financial Status"] ?? "").toLowerCase();

    const price = r["Item Price"] !== undefined ? num(r["Item Price"]) : num(r["Charged Amount"]) - num(r["Taxes Collected"]);
    const sign = status.includes("refund") ? -1 : status === "charged" || status === "" ? 1 : 0;
    if (!sign) continue;
    const usd = toUsd(Math.abs(price), r["Currency of Sale"] ?? "USD", rates) * (1 - PLAY_FEE) * sign;
    const days = out.get(pkg) ?? new Map<string, number>();
    days.set(day, (days.get(day) ?? 0) + usd);
    out.set(pkg, days);
  }
  return { out, lastDay };
}

export async function runPlaySales(env: Env) {
  if (!env.PLAY_BUCKET) return;
  const apps = APPS.filter((a) => a.playPackage);
  if (!apps.length) return;
  const tok = await googleToken(env, "https://www.googleapis.com/auth/devstorage.read_only");
  if (!tok) return;
  const H = { authorization: `Bearer ${tok}` };
  const rates = await fxToUsd(env.DB);
  const now = new Date();
  const months = [new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1)), now];
  let err = "";
  let any = false;
  for (const m of months) {
    const obj = encodeURIComponent(`sales/salesreport_${ym(m)}.zip`);
    const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${env.PLAY_BUCKET}/o/${obj}?alt=media`, { headers: H });
    if (r.status === 404) continue;
    if (r.status === 403 || r.status === 401) { err = "finansal veri izni yok"; continue; }
    if (!r.ok) { err = `depo ${r.status}`; continue; }
    const csv = unzipFirst(new Uint8Array(await r.arrayBuffer()));
    if (!csv) { err = "rapor açılamadı"; continue; }
    any = true;
    const { out, lastDay } = aggregatePlaySales(parseCsv(new TextDecoder("utf-8").decode(csv)), rates);
    if (!lastDay) continue;

    const first = `${ym(m).slice(0, 4)}-${ym(m).slice(4)}-01`;
    const stmts: D1PreparedStatement[] = [];
    const ins = env.DB.prepare("INSERT OR REPLACE INTO daily (app, metric, day, value) VALUES (?, ?, ?, ?)");
    for (let d = first; d <= lastDay; d = addDays(d, 1))
      for (const a of apps) stmts.push(ins.bind(a.id, "android_proceeds_usd", d, Math.round((out.get(a.playPackage!)?.get(d) ?? 0) * 100) / 100));
    if (stmts.length) await env.DB.batch(stmts);
  }
  for (const a of apps) await markSource(env, a.id, "play_sales", any || !err, any || !err ? "" : err);
}
