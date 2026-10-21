import { useEffect, useState } from "react";
import { Link, Outlet, matchRoutes, useLocation } from "react-router-dom";
import { captureError, setRouteTemplate } from "@appsignal/browser";
import { ErrorBoundary } from "@appsignal/browser/react";
import Catalogue from "./pages/Catalogue";
import OrderForm from "./pages/OrderForm";
import OrderStatus from "./pages/OrderStatus";
import { setTrackedRoute, track } from "./track";
import { ACCOUNTS, getAccount, switchAccount } from "./account";

// Reports the matched route template ("/orders/:reference"), not the URL, so
// errors and web vitals group per page instead of per order.
function RouteReporter() {
  const location = useLocation();
  useEffect(() => {
    const matches = matchRoutes(routes, location) || [];
    let template = "";
    for (const { route } of matches) {
      if (!route.path) continue;
      template = route.path.startsWith("/") ? route.path : `${template}/${route.path}`;
    }
    const route = template.replace(/\/+/g, "/") || "/";
    setRouteTemplate(route);
    setTrackedRoute(route);
    track("page_view", { route });
  }, [location.pathname]);
  return null;
}

function Page({ children }) {
  return (
    <ErrorBoundary captureError={captureError} fallback={<p className="notice error">Something went wrong on this page.</p>}>
      {children}
    </ErrorBoundary>
  );
}

// No real login in the demo: pick which customer account you're signed in as.
function AccountSwitcher() {
  const [account, setAccount] = useState(getAccount());
  return (
    <label className="account">
      <span>Signed in as</span>
      <select value={account.id} onChange={(e) => setAccount(switchAccount(e.target.value))}>
        {ACCOUNTS.map((a) => <option key={a.id} value={a.id}>{a.name} · {a.customer}</option>)}
      </select>
    </label>
  );
}

function Layout() {
  return (
    <>
      <RouteReporter />
      <header className="site-header">
        <Link to="/" className="brand">Ijzerhaven <span>Raw Materials</span></Link>
        <nav>
          <Link to="/">Catalogue</Link>
          <AccountSwitcher />
        </nav>
      </header>
      <main>
        <Outlet />
      </main>
      <footer>Rotterdam · Delft · Bulk metals, polymers and minerals for industry</footer>
    </>
  );
}

export const routes = [
  {
    path: "/",
    element: <Layout />,
    children: [
      { index: true, element: <Page><Catalogue /></Page> },
      { path: "order/:sku", element: <Page><OrderForm /></Page> },
      { path: "orders/:reference", element: <Page><OrderStatus /></Page> },
    ],
  },
];
