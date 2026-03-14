# Frontend

Location: `frontend/`

Stack:

- Vite
- React
- TypeScript

The console provides:

- Large order creation form.
- Mode selector (`BBE` / `SOF`).
- Slice-by-slice progress simulation.
- Realized average execution price vs naive baseline.
- Slice execution log.

Shared artifacts consumed from:

- `shared/types/order.ts`
- `shared/abis/*.json`
- `shared/constants/*`

Run locally (once Node is available):

```bash
npm --workspace frontend run dev
```
