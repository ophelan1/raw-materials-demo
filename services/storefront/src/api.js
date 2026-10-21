// Thin wrappers around the orders-web API (proxied at /api by nginx).
import { accountHeaders } from "./account";
import { timedFetch } from "./track";

export function euro(cents) {
  return new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100);
}

export async function getMaterials() {
  const response = await timedFetch("GET /api/materials", "/api/materials", { headers: accountHeaders() });
  if (!response.ok) throw new Error(`Catalogue unavailable (HTTP ${response.status})`);
  return response.json();
}

export async function getOrder(reference) {
  const response = await timedFetch("GET /api/orders/:reference", `/api/orders/${encodeURIComponent(reference)}`, { headers: accountHeaders() });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Order lookup failed (HTTP ${response.status})`);
  return response.json();
}

// Resolves with { status, body } for every answer the API gives, including
// declines (402) and payment failures (502); only network trouble throws.
export async function placeOrder(order) {
  const response = await timedFetch("POST /api/orders", "/api/orders", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Entrypoint": "storefront", ...accountHeaders() },
    body: JSON.stringify(order),
  });
  return { status: response.status, body: await response.json() };
}
