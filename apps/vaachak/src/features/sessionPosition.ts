import type { Item } from "../api/types";
/** Only personal sessions own a task cursor; lesson.position is a course ordinal. */
export function initialTaskIndex(data: {
  id?: string | number;
  position?: number;
  items?: Item[];
}) {
  const items = data.items || [];
  const personal =
    items[0]?.source?.practice_session_id === data.id &&
    typeof data.id === "string";
  const position = personal ? data.position : 0;
  return Number.isInteger(position) &&
    position! >= 0 &&
    position! < items.length
    ? position!
    : 0;
}
