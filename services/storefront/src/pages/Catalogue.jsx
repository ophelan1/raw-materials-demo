import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { euro, getMaterials } from "../api";

export default function Catalogue() {
  const [materials, setMaterials] = useState(null);
  const [error, setError] = useState(null);

  // A failed load rejects inside the effect and reaches window, so AppSignal
  // reports it without a captureError call; the page shows a notice too.
  useEffect(() => {
    getMaterials().then(setMaterials, (e) => { setError(e.message); throw e; });
  }, []);

  if (error) return <p className="notice error">{error}</p>;
  if (!materials) return <p className="notice">Loading catalogue…</p>;

  return (
    <>
      <section className="hero">
        <h1>Bulk raw materials, delivered from Rotterdam and Delft</h1>
        <p>Order by the tonne. Card payment or 30-day invoice for account customers.</p>
      </section>
      <div className="grid">
        {materials.map((m) => (
          <article key={m.sku} className="card">
            <div className="sku">{m.sku}</div>
            <h2>{m.name}</h2>
            <div className="price">{euro(m.price_cents)} <span>/ {m.unit}</span></div>
            <div className={m.stock < 200 ? "stock low" : "stock"}>{m.stock.toLocaleString("nl-NL")} {m.unit}s in stock</div>
            <Link className="button" to={`/order/${encodeURIComponent(m.sku)}`}>Order</Link>
          </article>
        ))}
      </div>
    </>
  );
}
