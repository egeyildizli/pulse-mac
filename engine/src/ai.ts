import type { Env } from "./env";

export type AiProvider = "anthropic" | "openai" | "gemini" | "ollama";
export const AI_DEFAULT_MODEL: Record<AiProvider, string> = {
  anthropic: "claude-sonnet-5-5",
  openai: "gpt-5-mini",
  gemini: "gemini-2.5-flash",
  ollama: "llama3.1",
};

export function aiConfig(env: Env) {
  const provider = (env.AI_PROVIDER as AiProvider | undefined) ?? (env.ANTHROPIC_API_KEY ? "anthropic" : undefined);
  if (!provider) return null;
  const key = env.AI_KEY ?? (provider === "anthropic" ? env.ANTHROPIC_API_KEY : undefined);
  if (provider !== "ollama" && !key) return null;
  return { provider, key: key ?? "", model: env.AI_MODEL || AI_DEFAULT_MODEL[provider], url: (env.AI_URL || "http://127.0.0.1:11434").replace(/\/$/, "") };
}

export async function complete(cfg: NonNullable<ReturnType<typeof aiConfig>>, system: string, user: string, maxTokens = 1500): Promise<string> {
  if (cfg.provider === "anthropic") {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": cfg.key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: cfg.model, max_tokens: maxTokens, system, messages: [{ role: "user", content: user }] }),
    });
    const j = (await r.json().catch(() => ({}))) as { content?: { type: string; text?: string }[]; stop_reason?: string; error?: { message: string } };
    if (!r.ok) throw new Error(`Anthropic ${r.status}: ${j.error?.message ?? ""}`);
    if (j.stop_reason === "refusal") return "";
    return (j.content ?? []).filter((b) => b.type === "text").map((b) => b.text ?? "").join("\n").trim();
  }
  if (cfg.provider === "openai") {
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { authorization: `Bearer ${cfg.key}`, "content-type": "application/json" },
      body: JSON.stringify({ model: cfg.model, max_completion_tokens: maxTokens, messages: [{ role: "system", content: system }, { role: "user", content: user }] }),
    });
    const j = (await r.json()) as { choices?: { message?: { content?: string } }[]; error?: { message: string } };
    if (!r.ok) throw new Error(`OpenAI ${r.status}: ${j.error?.message ?? ""}`);
    return j.choices?.[0]?.message?.content?.trim() ?? "";
  }
  if (cfg.provider === "gemini") {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(cfg.model)}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": cfg.key, "content-type": "application/json" },
      body: JSON.stringify({ systemInstruction: { parts: [{ text: system }] }, contents: [{ role: "user", parts: [{ text: user }] }], generationConfig: { maxOutputTokens: maxTokens } }),
    });
    const j = (await r.json()) as { candidates?: { content?: { parts?: { text?: string }[] } }[]; error?: { message: string } };
    if (!r.ok) throw new Error(`Gemini ${r.status}: ${j.error?.message ?? ""}`);
    return (j.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? "").join("").trim();
  }
  if (cfg.provider === "ollama") {
    const r = await fetch(`${cfg.url}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: cfg.model, stream: false, messages: [{ role: "system", content: system }, { role: "user", content: user }] }),
    });
    const j = (await r.json().catch(() => ({}))) as { message?: { content?: string }; error?: string };
    if (!r.ok) throw new Error(`Ollama ${r.status}: ${j.error ?? ""}`);
    return j.message?.content?.trim() ?? "";
  }
  throw new Error("bilinmeyen sağlayıcı");
}

export async function aiCheck(cfg: NonNullable<ReturnType<typeof aiConfig>>): Promise<string | null> {
  try {
    if (cfg.provider === "anthropic") {
      const r = await fetch("https://api.anthropic.com/v1/models?limit=1", { headers: { "x-api-key": cfg.key, "anthropic-version": "2023-06-01" } });
      return r.ok ? null : "Anthropic anahtarı reddetti. console.anthropic.com'dan yeni bir API anahtarı oluştur.";
    }
    if (cfg.provider === "ollama") {
      const r = await fetch(`${cfg.url}/api/tags`).catch(() => null);
      if (!r?.ok) return `Ollama'ya ulaşılamadı (${cfg.url}). Ollama'yı kurup açtığından emin ol.`;
      const j = (await r.json()) as { models?: { name: string }[] };
      const names = (j.models ?? []).map((m) => m.name);
      if (!names.some((n) => n === cfg.model || n.startsWith(cfg.model + ":"))) return `Bu model yüklü değil: ${cfg.model}. Terminalde "ollama pull ${cfg.model}" çalıştır. Yüklü olanlar: ${names.join(", ") || "yok"}.`;
      return null;
    }
    await complete(cfg, "Kısa cevap ver.", "Sadece OK yaz.", 20);
    return null;
  } catch (e) {
    return String(e instanceof Error ? e.message : e).slice(0, 300);
  }
}
