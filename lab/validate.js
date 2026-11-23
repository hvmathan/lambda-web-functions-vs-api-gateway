'use strict';

// Shared synthetic JSON validation logic used identically by:
// - Path A: Amazon API Gateway (HTTP API) + AWS Lambda Event Function
// - Path B: AWS Lambda Web Function (Express HTTP server)
function validatePayload(payload) {
  const rows = payload?.rows;
  if (!Array.isArray(rows)) {
    return {
      statusCode: 400,
      body: { error: 'rows must be an array' }
    };
  }

  const invalidRows = [];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const validId = typeof row?.id === 'string' && row.id.trim().length > 0;
    const validAmount =
      typeof row?.amount === 'number' &&
      Number.isFinite(row.amount) &&
      row.amount > 0;

    if (!validId || !validAmount) {
      invalidRows.push(i + 1);
    }
  }

  return {
    statusCode: 200,
    body: {
      rowCount: rows.length,
      invalidCount: invalidRows.length,
      invalidRows
    }
  };
}

module.exports = { validatePayload };
