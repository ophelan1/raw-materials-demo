import { useEffect, useState } from "react";
import { Link, useLocation, useParams } from "react-router-dom";
import { euro, getOrder } from "../api";

const LABELS = { paid: "Paid, dispatch scheduled", declined: "Declined by bank", failed: "Payment failed", pending: "Processing" };

export default function OrderStatus() {
  const { reference } = useParams();
  const { state } = useLocation();
  const [order, setOrder] = useState(undefined);

  useEffect(() => {
    getOrder(reference).then(setOrder, (e) => { setOrder(null); throw e; });
  }, [reference]);

  if (order === undefined) return <p className="notice">Loading order…</p>;
  if (order === null) return <p className="notice error">Order {reference} not found. <Link to="/">Back to the catalogue</Link></p>;

  return (
    <section className="order">
      <Link to="/" className="back">← Catalogue</Link>
      {state?.justPlaced && <p className="notice ok">Thanks, your order is placed.</p>}
      <h1>Order {order.reference}</h1>
      <dl className="details">
        <dt>Status</dt><dd className={`status ${order.status}`}>{LABELS[order.status] || order.status}</dd>
        <dt>Customer</dt><dd>{order.customer}</dd>
        <dt>Material</dt><dd>{order.sku}</dd>
        <dt>Quantity</dt><dd>{order.quantity}</dd>
        <dt>Total</dt><dd>{euro(order.total_cents)}</dd>
        <dt>Payment</dt><dd>{order.payment_method}</dd>
      </dl>
    </section>
  );
}
