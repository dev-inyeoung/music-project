export interface ReportPayload {
  entry_id: string;
  reason: string | null;
  report_count: number;
}

export const HIDE_THRESHOLD = 3;

export function buildEmail(
  p: ReportPayload,
  dashboardUrl: string,
): { subject: string; text: string } {
  const hidden = p.report_count >= HIDE_THRESHOLD;
  const subject = `${hidden ? "[숨김됨] " : ""}신고 접수: 글 ${p.entry_id} (${p.report_count}건)`;
  const text = [
    `entry_id: ${p.entry_id}`,
    `신고 횟수: ${p.report_count}`,
    `사유: ${p.reason ?? "(없음)"}`,
    hidden ? "신고가 누적되어 이 글은 자동으로 숨김 처리되었습니다." : "",
    `대시보드: ${dashboardUrl}`,
  ].filter((l) => l !== "").join("\n");
  return { subject, text };
}
