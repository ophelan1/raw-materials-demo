import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { captureError } from "@appsignal/browser";
import { CUSTOMERS, euro, getMaterials, placeOrder } from "../api";

export default function OrderForm() {
  const { sku } = useParams();
  const navigate = useNavigate();
  const [material, setMaterial] = useState(null);
  const [form, setForm] = useState({ customer: CUSTOMERS[0], quantity: 5, payment_method: "card" });
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState(null);

  useEffect(() => {
    getMaterials().then((all) => setMaterial(all.find((m) => m.sku === sku) || false));
  }, [sku]);

  async function submit(event) {
    event.preventDefault();
    setSubmitting(true);
    setResult(null);
    try {
      const { status, body } = await placeOrder({ ...form, sku, quantity: Number(form.quantity) });
      if (status === 201) {
        navigate(`/orders/${body.reference}`, { state: { justPlaced: true } });
        return;
      }
      // 402 (declined by the bank) and 409 (not enough stock) are answers, not
      // failures. 502 is a payment failure: the SDK already reports it as a
      // browser error linked to the back-end trace, so it isn't reported twice.
      setResult({ status, body });
    } catch (error) {
      // Network failure or an unreadable response: unexpected, so report it.
      captureError(error, { sku, payment_method: form.payment_method });
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
            onChange={() => setForm({ ...form, payment_method: "invoice" })} /> Invoice (30 days)</label>
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
