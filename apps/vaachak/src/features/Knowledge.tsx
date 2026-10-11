import React, { useRef, useState } from "react";
import * as Crypto from "expo-crypto";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ApiError, get, send } from "../api/client";
import type { components } from "../api/schema";
import skills from "../api/skills.json";
import {
  Button,
  Card,
  Confirm,
  Empty,
  ErrorBox,
  Field,
  Label,
  Page,
  Pill,
  QueryState,
  Row,
  Title,
} from "../components/ui";

type Note = components["schemas"]["KnowledgeUnit"];
const path = "/teacher/knowledge";
const statuses = {
  draft: "Draft · only you",
  approved: "Reviewed · only you",
  published: "Published · shared",
  withdrawn: "Withdrawn · only you",
};
const skillLabel = (code: string) =>
  skills.find((s) => s.code === code)?.label || code;

export function Knowledge() {
  const cache = useQueryClient();
  const q = useQuery({
    queryKey: [path],
    queryFn: () => get<{ units: Note[] }>(path),
  });
  const [editor, setEditor] = useState<Note | null | undefined>();
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<"mine" | "shared">("mine");
  const [open, setOpen] = useState("");
  const [notice, setNotice] = useState("");

  function remember(note: Note) {
    cache.setQueryData<{ units: Note[] }>([path], (old) => ({
      units: [note, ...(old?.units || []).filter((n) => n.id !== note.id)],
    }));
    void cache.invalidateQueries({ queryKey: [path] });
  }
  async function transition(
    note: Note,
    action: "review" | "publish" | "withdraw",
  ) {
    const result = await send<Note>(`${path}/${note.id}/${action}`, {
      version: note.version,
    });
    remember(result);
    setNotice(
      action === "publish"
        ? "Published. This note can now support learner feedback."
        : action === "review"
          ? "Reviewed. Publish when you are ready to share it with learners."
          : "Withdrawn. This note will no longer be used for new feedback.",
    );
  }

  if (editor !== undefined)
    return (
      <NoteEditor
        key={editor?.id || "new"}
        note={editor}
        onCancel={() => setEditor(undefined)}
        onSaved={(note) => {
          remember(note);
          setEditor(undefined);
          setFilter("mine");
          setSearch("");
          setOpen(note.id);
          setNotice("Draft saved. Read it through before marking it reviewed.");
        }}
      />
    );

  return (
    <Page
      refresh={() => {
        void q.refetch();
      }}
      refreshing={q.isRefetching}
    >
      <Pill text="TEACHING KNOWLEDGE" />
      <Title>Better explanations, together.</Title>
      <Label muted>
        Write a short teaching note, check its accuracy, then share it. The
        coach can cite published notes when they are relevant to a learner’s
        answer.
      </Label>
      <Button
        title="Write a teaching note"
        icon="create-outline"
        onPress={() => {
          setNotice("");
          setEditor(null);
        }}
      />
      {!!notice && <Label style={{ fontWeight: "600" }}>{notice}</Label>}
      <Row>
        <Button
          title="My notes"
          kind={filter === "mine" ? "primary" : "secondary"}
          onPress={() => setFilter("mine")}
        />
        <Button
          title="Shared library"
          kind={filter === "shared" ? "primary" : "secondary"}
          onPress={() => setFilter("shared")}
        />
      </Row>
      <Field
        label="Search teaching notes"
        value={search}
        onChangeText={setSearch}
        placeholder="A topic, skill or explanation"
      />
      <Button
        title="Refresh notes"
        kind="quiet"
        busy={q.isRefetching}
        onPress={() => {
          void q.refetch();
        }}
      />
      <QueryState query={q}>
        {({ units }: { units: Note[] }) => {
          const matching = units.filter(
            (note) =>
              (filter === "mine"
                ? note.can_manage
                : note.status === "published") &&
              `${note.title} ${note.body} ${skillLabel(note.skill_code)}`
                .toLowerCase()
                .includes(search.trim().toLowerCase()),
          );
          return matching.length ? (
            matching.map((note) => (
              <Card key={note.id}>
                <Row>
                  <Pill
                    text={statuses[note.status]}
                    tone={note.status === "published" ? "green" : "blue"}
                  />
                  <Label muted>
                    {note.level} · v{note.version}
                  </Label>
                </Row>
                <Title small>{note.title}</Title>
                <Label muted>{skillLabel(note.skill_code)}</Label>
                <Button
                  title={
                    open === note.id
                      ? `Close ${note.title}`
                      : `Open ${note.title}`
                  }
                  kind="quiet"
                  onPress={() => setOpen(open === note.id ? "" : note.id)}
                />
                {open === note.id && (
                  <>
                    <Label>{note.body}</Label>
                    {!!note.example && (
                      <Card>
                        <Label muted>Example</Label>
                        <Label>{note.example}</Label>
                      </Card>
                    )}
                    <Label muted>
                      {note.source} · {note.language.toUpperCase()}
                    </Label>
                    {note.can_manage && (
                      <>
                        <Button
                          title="Edit teaching note"
                          kind="secondary"
                          onPress={() => {
                            setNotice("");
                            setEditor(note);
                          }}
                        />
                        {note.status === "draft" && (
                          <Confirm
                            title="Mark as reviewed"
                            body="Check the explanation and example for accuracy, clarity and respectful language. Your review applies to this version only."
                            label="I have reviewed this note"
                            onConfirm={() => transition(note, "review")}
                          />
                        )}
                        {note.status === "approved" && (
                          <Confirm
                            title="Publish teaching note"
                            body="This makes the note available to all learners and teachers. Only publish material you are allowed to share, without private student information."
                            label="Publish to shared library"
                            onConfirm={() => transition(note, "publish")}
                          />
                        )}
                        {(note.status === "approved" ||
                          note.status === "published") && (
                          <Confirm
                            title="Withdraw teaching note"
                            body="Stop using this note for new feedback. Previous attempts keep their original source reference. You can edit and review a new version later."
                            label="Withdraw this note"
                            onConfirm={() => transition(note, "withdraw")}
                          />
                        )}
                      </>
                    )}
                  </>
                )}
              </Card>
            ))
          ) : (
            <Empty
              title={
                search
                  ? "No matching notes"
                  : filter === "mine"
                    ? "Your first helpful explanation"
                    : "No shared notes yet"
              }
              body={
                search
                  ? "Try a different word or switch libraries."
                  : "Start with one common mistake and a clear example. Drafts stay private until you review and publish them."
              }
            />
          );
        }}
      </QueryState>
    </Page>
  );
}

function NoteEditor({
  note,
  onSaved,
  onCancel,
}: {
  note: Note | null;
  onSaved: (note: Note) => void;
  onCancel: () => void;
}) {
  const [title, setTitle] = useState(note?.title || "");
  const [body, setBody] = useState(note?.body || "");
  const [example, setExample] = useState(note?.example || "");
  const [skill, setSkill] = useState(note?.skill_code || "MORPH.AGREEMENT");
  const [level, setLevel] = useState(note?.level || "A1");
  const [chooseSkill, setChooseSkill] = useState(false);
  const [skillSearch, setSkillSearch] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const saving = useRef(false);
  const clientId = useRef(Crypto.randomUUID());
  // Retrying an uncertain create must reuse the exact payload as well as its key.
  const attempted = useRef<string | undefined>(undefined);
  const valid =
    title.trim().length >= 2 &&
    title.trim().length <= 120 &&
    body.trim().length >= 2 &&
    body.trim().length <= 2000 &&
    example.trim().length <= 300;
  async function save() {
    if (saving.current || !valid) return;
    saving.current = true;
    setBusy(true);
    setError(undefined);
    try {
      const values = {
        title: title.trim(),
        body: body.trim(),
        example: example.trim() || null,
        skill_code: skill,
        level,
        language: note?.language || "en",
      };
      const serialized = JSON.stringify(values);
      if (!note && attempted.current && attempted.current !== serialized) {
        throw new Error(
          "A previous save may have reached the server. Retry with the same text, or return to your notes and refresh before starting another draft.",
        );
      }
      attempted.current = serialized;
      onSaved(
        await send<Note>(
          note ? `${path}/${note.id}` : path,
          {
            ...values,
            ...(note
              ? { version: note.version }
              : { client_uuid: clientId.current }),
          },
          note ? "PUT" : "POST",
        ),
      );
    } catch (e) {
      if (e instanceof ApiError && [400, 422].includes(e.status))
        attempted.current = undefined;
      setError(e);
    } finally {
      saving.current = false;
      setBusy(false);
    }
  }
  return (
    <Page>
      <Pill text="PRIVATE DRAFT" />
      <Title>
        {note ? "Refine your explanation." : "One clear idea helps."}
      </Title>
      <Label muted>
        Use a simple explanation and a natural example. Keep personal learner
        information out of your note.
      </Label>
      {!!note && note.status !== "draft" && (
        <Card>
          <Label>
            Saving changes withdraws the current version from new feedback.
            Review and publish the new draft when it is ready.
          </Label>
        </Card>
      )}
      <Card>
        <Field
          label="Note title"
          value={title}
          onChangeText={setTitle}
          disabled={busy}
        />
        <Label muted>{title.length}/120 characters</Label>
        <Label muted>Learning focus</Label>
        <Button
          title={`Skill: ${skillLabel(skill)}`}
          kind="secondary"
          disabled={busy}
          onPress={() => setChooseSkill(!chooseSkill)}
        />
        {chooseSkill && (
          <>
            <Field
              label="Find a skill"
              value={skillSearch}
              onChangeText={setSkillSearch}
              disabled={busy}
            />
            {skills
              .filter((s) =>
                `${s.label} ${s.domain}`
                  .toLowerCase()
                  .includes(skillSearch.toLowerCase()),
              )
              .map((s) => (
                <Button
                  key={s.code}
                  title={s.label}
                  kind={skill === s.code ? "primary" : "quiet"}
                  disabled={busy}
                  onPress={() => {
                    setSkill(s.code);
                    setChooseSkill(false);
                  }}
                />
              ))}
          </>
        )}
        <Label muted>Learning level</Label>
        <Row>
          {["A1", "A2", "B1", "B2", "C1", "C2"].map((value) => (
            <Button
              key={value}
              title={value}
              kind={level === value ? "primary" : "secondary"}
              disabled={busy}
              onPress={() => setLevel(value)}
            />
          ))}
        </Row>
        <Field
          label="Explanation"
          value={body}
          onChangeText={setBody}
          multiline
          disabled={busy}
        />
        <Label muted>{body.length}/2000 characters</Label>
        <Field
          label="Example (optional)"
          value={example}
          onChangeText={setExample}
          multiline
          disabled={busy}
        />
        <Label muted>{example.length}/300 characters</Label>
        <ErrorBox error={error} />
        <Button
          title="Save private draft"
          busy={busy}
          disabled={!valid}
          onPress={save}
        />
        {!busy && (
          <Confirm
            title="Back to teaching notes"
            body="Leave this editor? Changes you have not saved will be lost. Saved drafts remain in My notes."
            label="Leave editor"
            onConfirm={async () => onCancel()}
          />
        )}
      </Card>
    </Page>
  );
}
