const { createHash } = require('node:crypto');
const { app, output } = require('@azure/functions');

let sql;
let poolPromise;

const paymentResult = output.serviceBusQueue({
  queueName: process.env.PAYMENT_RESULT_QUEUE || 'payment-results',
  connection: 'SERVICE_BUS_CONNECTION',
});

function processPaymentRequest(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    throw new Error('Payment request must be a JSON object.');
  }

  const paymentRequestId = request.paymentRequestId;
  const orderId = request.orderId || request.sourceOrderId;
  const amount = Number(request.amount);
  const currency = request.currency;

  if (typeof paymentRequestId !== 'string' || !paymentRequestId.trim()) {
    throw new Error('Payment request must include paymentRequestId.');
  }
  if (typeof orderId !== 'string' || !orderId.trim()) {
    throw new Error('Payment request must include orderId or sourceOrderId.');
  }
  if (!Number.isFinite(amount) || amount < 0) {
    throw new Error('Payment request amount must be a non-negative number.');
  }
  if (typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) {
    throw new Error('Payment request currency must be a 3-letter uppercase code.');
  }

  const declined = request.simulateOutcome === 'declined';
  const reference = createHash('sha256')
    .update(paymentRequestId)
    .digest('hex')
    .slice(0, 16)
    .toUpperCase();

  return {
    paymentRequestId,
    orderId,
    status: declined ? 'Declined' : 'Approved',
    amount,
    currency,
    transactionReference: `MOCK-${reference}`,
    processedAt: new Date().toISOString(),
    simulator: true,
  };
}

function normalizePaymentResult(result) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) {
    throw new Error('Payment result must be a JSON object.');
  }

  const paymentRequestId = result.paymentRequestId;
  const orderId = result.orderId || result.sourceOrderId;
  const amount = Number(result.amount);
  const currency = result.currency;
  const status = result.status;
  const transactionReference = result.transactionReference;
  const processedAt = new Date(result.processedAt);

  if (typeof paymentRequestId !== 'string' || !paymentRequestId.trim() || paymentRequestId.length > 100) {
    throw new Error('Payment result must include a paymentRequestId of at most 100 characters.');
  }
  if (typeof orderId !== 'string' || !orderId.trim() || orderId.length > 100) {
    throw new Error('Payment result must include an orderId of at most 100 characters.');
  }
  if (!Number.isFinite(amount) || amount < 0 || amount > 9999999999.99 || Math.round(amount * 100) !== amount * 100) {
    throw new Error('Payment result amount must be a non-negative value with at most two decimal places.');
  }
  if (typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) {
    throw new Error('Payment result currency must be a 3-letter uppercase code.');
  }
  if (status !== 'Approved' && status !== 'Declined') {
    throw new Error('Payment result status must be Approved or Declined.');
  }
  if (typeof transactionReference !== 'string' || !transactionReference.trim() || transactionReference.length > 100) {
    throw new Error('Payment result must include a transaction reference of at most 100 characters.');
  }
  if (!Number.isFinite(processedAt.getTime())) {
    throw new Error('Payment result must include a valid processedAt timestamp.');
  }

  return { paymentRequestId, orderId, amount, currency, status, transactionReference, processedAt };
}

async function getSqlPool() {
  const server = process.env.SQL_SERVER;
  const database = process.env.SQL_DATABASE;
  if (!server || !database) {
    throw new Error('SQL_SERVER and SQL_DATABASE application settings are required.');
  }

  if (!poolPromise) {
    sql = require('mssql');
    poolPromise = new sql.ConnectionPool({
      server,
      database,
      options: { encrypt: true, trustServerCertificate: false },
      authentication: { type: 'azure-active-directory-default' },
    }).connect();
    poolPromise.catch(() => { poolPromise = undefined; });
  }
  return poolPromise;
}

async function savePaymentResult(rawResult) {
  const result = normalizePaymentResult(rawResult);
  const pool = await getSqlPool();
  const transaction = new sql.Transaction(pool);
  await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);

  try {
    const existing = await new sql.Request(transaction)
      .input('paymentRequestId', sql.NVarChar(100), result.paymentRequestId)
      .query('SELECT 1 FROM dbo.PaymentResults WITH (UPDLOCK, HOLDLOCK) WHERE PaymentRequestId = @paymentRequestId;');

    if (existing.recordset.length) {
      await transaction.commit();
      return { duplicate: true, result };
    }

    const order = await new sql.Request(transaction)
      .input('orderId', sql.NVarChar(100), result.orderId)
      .query('SELECT Status FROM dbo.ShoppingLists WITH (UPDLOCK, HOLDLOCK) WHERE SourceOrderId = @orderId;');

    if (!order.recordset.length) {
      throw new Error(`No shopping list matches payment order ${result.orderId}.`);
    }
    if (order.recordset[0].Status !== 'PaymentPending') {
      throw new Error(`Order ${result.orderId} is not awaiting payment.`);
    }

    await new sql.Request(transaction)
      .input('paymentRequestId', sql.NVarChar(100), result.paymentRequestId)
      .input('orderId', sql.NVarChar(100), result.orderId)
      .input('status', sql.VarChar(16), result.status)
      .input('amount', sql.Decimal(12, 2), result.amount)
      .input('currency', sql.Char(3), result.currency)
      .input('transactionReference', sql.NVarChar(100), result.transactionReference)
      .input('processedAt', sql.DateTimeOffset(0), result.processedAt)
      .query(`
        INSERT INTO dbo.PaymentResults
          (PaymentRequestId, SourceOrderId, Status, Amount, CurrencyCode, TransactionReference, ProcessedAt)
        VALUES
          (@paymentRequestId, @orderId, @status, @amount, @currency, @transactionReference, @processedAt);

        UPDATE dbo.ShoppingLists
        SET Status = CASE WHEN @status = 'Approved' THEN 'Paid' ELSE 'PaymentFailed' END,
            UpdatedAt = SYSUTCDATETIME()
        WHERE SourceOrderId = @orderId AND Status = 'PaymentPending';
      `);

    await transaction.commit();
    return { duplicate: false, result };
  } catch (error) {
    try {
      await transaction.rollback();
    } catch {
      // Preserve the original processing error.
    }
    throw error;
  }
}

app.serviceBusQueue('mockPaymentEngine', {
  connection: 'SERVICE_BUS_CONNECTION',
  queueName: process.env.PAYMENT_REQUEST_QUEUE || 'payment-requests',
  return: paymentResult,
  handler: async (message, context) => {
    const result = processPaymentRequest(message);
    context.log(`Mock payment ${result.status} for order ${result.orderId}; request ${result.paymentRequestId}.`);
    return result;
  },
});

app.serviceBusQueue('paymentResultHandler', {
  connection: 'SERVICE_BUS_CONNECTION',
  queueName: process.env.PAYMENT_RESULT_QUEUE || 'payment-results',
  handler: async (message, context) => {
    const { duplicate, result } = await savePaymentResult(message);
    context.log(duplicate
      ? `Ignored duplicate payment result ${result.paymentRequestId}.`
      : `Recorded ${result.status} payment for order ${result.orderId}; request ${result.paymentRequestId}.`);
  },
});

module.exports = { processPaymentRequest, normalizePaymentResult, savePaymentResult };