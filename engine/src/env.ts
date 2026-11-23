export interface Env {
  DB: D1Database;
  PULSE_TOKEN: string;

  ASC_KEY_ID?: string;
  ASC_ISSUER_ID?: string;
  ASC_P8?: string;
  ASC_VENDOR?: string;

  RC_KEYS?: string;

  STRIPE_KEYS?: string;

  GA4_SA?: string;

  CF_API_TOKEN?: string;
  CF_ACCOUNT_ID?: string;
  ANTHROPIC_API_KEY?: string;

  LANG?: string;

  AI_PROVIDER?: string;
  AI_KEY?: string;
  AI_MODEL?: string;
  AI_URL?: string;

  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_CHAT_ID?: string;

  WEBHOOK_SECRET?: string;
  WEBHOOK_URL?: string;

  META_TOKEN?: string;

  PLAY_BUCKET?: string;
}
