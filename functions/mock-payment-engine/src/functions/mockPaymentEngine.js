const { createHash } = require('node:crypto');
const { app, output } = require('@azure/functions');

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

module.exports = { processPaymentRequest };