import type { Item } from "./types";
export function validateItem(item: Item): string | null {
  const quiz = ["choice", "fill", "listen"].includes(item.kind);
  if (["read", "listen"].includes(item.kind) && !item.text?.trim())
    return "Add a sentence to read or hear.";
  if (["free", "choice", "fill"].includes(item.kind) && !item.prompt?.trim())
    return "Write a clear prompt for this task.";
  if (item.kind === "fill" && !item.prompt?.includes("___"))
    return "Mark the blank with three underscores (___).";
  if (
    item.kind === "build" &&
    (!item.words?.length ||
      item.words.some((w) => !w.trim()) ||
      !item.answer?.trim())
  )
    return "Add the words and the completed sentence.";
  if (quiz) {
    const options = item.options || [];
    if (
      options.length < 2 ||
      options.length > 6 ||
      options.some((o) => !o.trim())
    )
      return "Add between two and six non-empty options.";
    if (
      new Set(options.map((o) => o.trim().toLowerCase())).size !==
      options.length
    )
      return "Use a different answer for each option.";
    if (
      item.correct === undefined ||
      item.correct < 0 ||
      item.correct >= options.length
    )
      return "Choose the correct answer.";
  }
  return null;
}
