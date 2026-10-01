# Mock payment engine

This Azure Functions v4 Node.js app listens to the `payment-requests` Service Bus queue and writes a simulated result to `payment-results`. It does not process real payment credentials or charge cards.

## Message contract

Send a JSON message like this to `payment-requests`:

```json
{
  "paymentRequestId": "payreq-10001",
  "orderId": "SP-28471",
  "amount": 26.9,
  "currency": "GBP"
}
```

Valid requests are approved by default. Set `"simulateOutcome": "declined"` to test a decline. The transaction reference is stable for a given `paymentRequestId`; the result handler should still deduplicate because Service Bus delivers at least once.

## Azure setup

1. Create a `payment-results` queue in the same Service Bus namespace as `payment-requests`.
2. Enable the Function App system-assigned managed identity.
3. Grant that identity **Azure Service Bus Data Receiver** and **Azure Service Bus Data Sender** on the namespace.
4. In Function App application settings, set `SERVICE_BUS_CONNECTION__fullyQualifiedNamespace` to `<namespace-name>.servicebus.windows.net`. The queue settings default to `payment-requests` and `payment-results`; override them only if your queue names differ.
5. Confirm the app is configured for Azure Functions runtime v4 and Node.js 20, then use the GitHub deployment workflow described below.

The namespace must allow the Function App to reach its network endpoint. If public network access is disabled, configure private networking for the Function App.

## GitHub deployment

The workflow at `.github/workflows/deploy-mock-payment-engine.yml` deploys this folder to the existing Function App named `mock-payment-engine` when changes are pushed to `main`.

1. In the Azure portal, open the Function App, choose **Get publish profile**, and download its profile.
2. In GitHub, open the `cloud5` repository's **Settings → Secrets and variables → Actions → New repository secret**.
3. Name the secret `AZURE_FUNCTIONAPP_PUBLISH_PROFILE` and paste the downloaded publish profile as its value. Treat it as a deployment credential; do not commit it or share it.
4. Push a change under `functions/mock-payment-engine/` to `main`, or run **Deploy mock payment engine** manually from the repository's **Actions** tab.

The publish profile is used only by GitHub Actions to deploy code. At runtime, the Function connects to Service Bus using its managed identity.

## Local development

Install Node.js 20 and Azure Functions Core Tools v4. Copy `local.settings.sample.json` to `local.settings.json`, configure local storage and a Service Bus connection for development, then run:

```powershell
npm install
npm start
```

Do not commit `local.settings.json`; it may contain credentials.

## Scope

This processor only emits a simulated payment result. A separate result handler must validate `payment-results` and update SQL. The collection API should enqueue requests through the SQL outbox pattern; the browser must not connect directly to SQL or Service Bus.