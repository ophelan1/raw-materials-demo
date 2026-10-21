// The signed-in buyer. The demo has no login, so each browser gets one of the
// customer accounts below (remembered in localStorage) and the header lets you
// switch. The account is attached to everything AppSignal records:
//  - browser errors (setTags) and the browser session (setUser);
//  - back-end traces, through the X-User-* headers on every API call, which
//    orders-web and payments-api turn into span tags.
import { setTags, setUser } from "@appsignal/browser";

export const ACCOUNTS = [
  { id: "usr_1001", name: "Anouk Jansen", email: "anouk.jansen@delftsteelworks.example", customer: "Delft Steelworks", tier: "key_account" },
  { id: "usr_1002", name: "Daan Visser", email: "d.visser@rotterdamfab.example", customer: "Rotterdam Fabrication BV", tier: "key_account" },
  { id: "usr_1003", name: "Sanne de Boer", email: "sanne@eindhovenprecision.example", customer: "Eindhoven Precision Parts", tier: "standard" },
  { id: "usr_1004", name: "Lars Mulder", email: "inkoop@twenteplastics.example", customer: "Twente Plastics", tier: "standard" },
  { id: "usr_1005", name: "Fleur Bakker", email: "f.bakker@zeelandshipyards.example", customer: "Zeeland Shipyards", tier: "key_account" },
  { id: "usr_1006", name: "Thijs Smit", email: "thijs.smit@utrechtconstruction.example", customer: "Utrecht Construction Group", tier: "standard" },
  { id: "usr_1007", name: "Emma Meijer", email: "emma.meijer@groningencable.example", customer: "Groningen Cable Co", tier: "trial" },
  { id: "usr_1008", name: "Ruben de Wit", email: "r.dewit@maasfoundry.example", customer: "Maas Foundry", tier: "standard" },
];

let current = load();
apply(current);

function load() {
  try {
    const saved = ACCOUNTS.find((a) => a.id === localStorage.getItem("sf_account"));
    if (saved) return saved;
  } catch { /* storage blocked */ }
  const picked = ACCOUNTS[Math.floor(Math.random() * ACCOUNTS.length)];
  try { localStorage.setItem("sf_account", picked.id); } catch { /* storage blocked */ }
  return picked;
}

function apply(account) {
  setUser({ id: account.id, email: account.email, name: account.name });
  setTags({ user_id: account.id, user_email: account.email, customer: account.customer, account_tier: account.tier });
}

export function getAccount() {
  return current;
}

export function switchAccount(id) {
  current = ACCOUNTS.find((a) => a.id === id) || current;
  try { localStorage.setItem("sf_account", current.id); } catch { /* storage blocked */ }
  apply(current);
  return current;
}

// Sent on every API call so back-end spans carry the same user.
export function accountHeaders() {
  return {
    "X-Customer": current.customer,
    "X-User-Id": current.id,
    "X-User-Email": current.email,
    "X-Account-Tier": current.tier,
  };
}
