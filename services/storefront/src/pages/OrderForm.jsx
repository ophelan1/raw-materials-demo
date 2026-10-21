import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { captureError } from "@appsignal/browser";
import { CUSTOMERS, euro, getMaterials, placeOrder } from "../api";
import { track } from "../track";

// The answer the API gave, as a funnel step.
const OUTCOMES = { 201: "order_paid", 402: "order_declined", 409: "out_of_stock", 502: "order_failed" };

export default function OrderForm() {
  const { sku } = useParams();
  const navigate = useNavigate();
  const [material, setMaterial] = useState(null);
  const [form, setForm] = useState({ customer: CUSTOMERS[0], quantity: 5, payment_method: "card" });
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState(null);
  const openedAt = useRef(performance.now());
  const failures = useRef(0);

  useEffect(() => {
    openedAt.current = performance.now();
    failures.current = 0;
    track("funnel", { step: "view_product", sku });
    getMaterials().then((all) => setMaterial(all.find((m) => m.sku === sku) || false));
  }, [sku]);

  async function submit(event) {
    event.preventDefault();
    setSubmitting(true);
    setResult(null);
    track("funnel", { step: "submit_order", sku, payment_method: form.payment_method });
    track("checkout_time", { payment_method: form.payment_method, ms: Math.round(performance.now() - openedAt.current) });
    // A second try after a failed payment is a frustrated customer, not a new order.
    if (failures.current > 0) track("retry_after_failure", { payment_method: form.payment_method });
    try {
      const { status, body } = await placeOrder({ ...form, sku, quantity: Number(form.quantity) });
      track("funnel", { step: OUTCOMES[status] || "order_error", sku, payment_method: form.payment_method });
      if (status === 201) {
        navigate(`/orders/${body.reference}`, { state: { justPlaced: true } });
        return;
      }
      // 402 (declined by the bank) and 409 (not enough stock) are answers, not
      // failures. 502 is a payment failure: the SDK already reports it as a
      // browser error linked to the back-end trace, so it isn't reported twice.
      if (status === 502) failures.current += 1;
      setResult({ status, body });
    } catch (error) {
      // Network failure or an unreadable response: unexpected, so report it.
      captureError(error, { sku, payment_method: form.payment_method });
      track("funnel", { step: "network_error", sku, payment_method: form.payment_method });
      setResult({ status: 0, body: { error: "network_error" } });
    } finally {
      setSubmitting(false);
    }
  }

  if (material === null) return <p className="notice">Loading…</p>;
  if (material === false) return <p className="notice error">Unknown material {sku}. <Link to="/">Back to the catalogue</Link></p>;

  const total = material.price_cents * Number(form.quantity || 0);

  return (
    <section className="order">
      <Link to="/" className="back">← Catalogue</Link>
      <h1>{material.name}</h1>
      <p className="muted">{material.sku} · {euro(material.price_cents)} per {material.unit} · {material.stock.toLocaleString("nl-NL")} in stock</p>

      <form onSubmit={submit}>
        <label>
          Customer
          <select value={form.customer} onChange={(e) => setForm({ ...form, customer: e.target.value })}>
            {CUSTOMERS.map((c) => <option key={c}>{c}</option>)}
          </select>
        </label>
        <label>
          Quantity ({material.unit}s)
          <input type="number" min="1" max="500" value={form.quantity}
            onChange={(e) => setForm({ ...form, quantity: e.target.value })} />
        </label>
        <fieldset>
          <legend>Payment</legend>
          <label className="inline"><input type="radio" name="pm" checked={form.payment_method === "card"}
            onChange={() => setForm({ ...form, payment_method: "card" })} /> Card</label>
          <label className="inline"><input type="radio" name="pm" checked={form.payment_method === "invoice"}
            onChange={() => {
              // Switching to invoice right after a card failure: the workaround the failure notice offers.
              if (failures.current > 0) track("switched_to_invoice", {});
              setForm({ ...form, payment_method: "invoice" });
            }} /> Invoice (30 days)</label>
        </fieldset>
        <div className="total">Total <strong>{euro(total)}</strong></div>
        <button type="submit" className="button" disabled={submitting}>{submitting ? "Placing order…" : "Place order"}</button>
      </form>

      {result && <OrderProblem {...result} />}
    </section>
  );
}

function OrderProblem({ status, body }) {
  if (status === 402) return <p className="notice warn">Your bank declined the payment ({body.error}). Try another card or pay by invoice.</p>;
  if (status === 409) return <p className="notice warn">Not enough stock for that quantity.</p>;
  if (status === 502) {
    return (
      <p className="notice error">
        We couldn't take the payment right now (order {body.reference}). Nothing was charged. Please try again in a few minutes, or pay by invoice.
      </p>
    );
  }
  return <p className="notice error">Something went wrong placing the order. Please try again.</p>;
}
