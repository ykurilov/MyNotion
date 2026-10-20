export type ErrorCode =
  | 'unauthorized'
  | 'invite_expired'
  | 'too_large'
  | 'log_compacted'
  | 'server_error'
  | 'bad_request'
  | 'not_found'
  | 'file_complete'
  | 'file_incomplete'
  | 'storage_full';

/** Ошибка с готовым HTTP-статусом и текстом для Юрия: app.ts превращает её в единый JSON. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
    readonly extra: Record<string, unknown> = {},
  ) {
    super(message);
  }
}
