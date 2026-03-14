export type ExecutionMode = "BBE" | "SOF";

export type OrderStatus = "ACTIVE" | "CANCELLED" | "COMPLETED" | "EXPIRED";

export interface OrderDraft {
  tokenIn: string;
  tokenOut: string;
  amountInTotal: string;
  mode: ExecutionMode;
  maxSliceAmount: string;
  minSliceAmount: string;
  maxImpactBps: number;
  minAmountOutPerSlice: string;
}

export interface ProgressSnapshot {
  totalIn: number;
  totalOut: number;
  slicesExecuted: number;
  averagePrice: number;
  baselinePrice: number;
}
