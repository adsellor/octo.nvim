---Domain types that cross the forge seam. Annotations only.
---
---Every value an adapter hands back obeys these invariants:
---  * JSON nulls are nil, never vim.NIL.
---  * Timestamps are ISO-8601 UTC strings, e.g. "2026-10-27T12:00:00Z".
---  * Lines are 1-based file line numbers on a side, never diff positions.
---  * Ids are opaque strings; only the adapter that produced an id may interpret it.
---  * Values are snapshots: mutating one never changes forge state.

---LEFT is the base (old) version of a file, RIGHT the head (new) version.
---@alias octo.forge.Side "LEFT"|"RIGHT"

---git's status letters: added, modified, deleted, renamed, copied.
---@alias octo.forge.FileStatus "A"|"M"|"D"|"R"|"C"

---"dismissed" means viewed, but the file changed since.
---@alias octo.forge.ViewedState "viewed"|"unviewed"|"dismissed"

---@alias octo.forge.Verdict "comment"|"approve"|"request_changes"

---@alias octo.forge.PullRequestState "open"|"closed"|"merged"

---Optional behaviour; check with `forge:supports(feature)` before offering it.
---  draft            comments can be held in a pending review until `submit`
---  viewed           per-file viewed state
---  resolve          threads can be resolved
---  commit_comments  new threads can anchor to a single commit's diff
---  reactions        comments carry reactions the viewer can add and remove
---@alias octo.forge.Feature "draft"|"viewed"|"resolve"|"commit_comments"|"reactions"

---@alias octo.forge.ReactionContent "THUMBS_UP"|"THUMBS_DOWN"|"LAUGH"|"HOORAY"|"CONFUSED"|"HEART"|"ROCKET"|"EYES"

---@class octo.forge.RepoRef
---@field host string e.g. "github.com", "bitbucket.org"
---@field owner string GitHub owner or Bitbucket workspace
---@field name string

---@class octo.forge.PullRequestRef
---@field repo octo.forge.RepoRef
---@field number integer

---@class octo.forge.User
---@field login string

---@class octo.forge.Branch
---@field name string
---@field sha string
---@field repo octo.forge.RepoRef differs from the base repo for pull requests from forks

---A branch to look a pull request up by.
---@class octo.forge.Head
---@field name string
---@field repo? octo.forge.RepoRef the repository the branch lives in, when known; narrows the search to it

---Which pull requests a listing returns. Every field narrows it; nil means any.
---@class octo.forge.PullRequestFilter
---@field states? octo.forge.PullRequestState[] default { "open" }
---@field head? octo.forge.Head
---@field base? string the base branch's name
---@field labels? string[] carrying all of these labels; forges without labels fail when given any
---@field order? { field: "created"|"updated", direction: "asc"|"desc" } default newest created first

---A pull request as a listing shows it: no commits and no merge base.
---@class octo.forge.PullRequestSummary
---@field ref octo.forge.PullRequestRef
---@field title string
---@field body string
---@field state octo.forge.PullRequestState
---@field draft boolean
---@field author octo.forge.User
---@field url string
---@field base { name: string, repo: octo.forge.RepoRef }
---@field head { name: string, repo: octo.forge.RepoRef } repo differs from the base repo for forks
---@field labels string[]
---@field created_at string
---@field updated_at string
---@field queued? boolean waiting in a merge queue
---@field stack? { position: integer, size: integer } its place in a stack of pull requests

---@class octo.forge.PullRequest
---@field ref octo.forge.PullRequestRef
---@field id string
---@field title string
---@field body string
---@field state octo.forge.PullRequestState
---@field draft boolean
---@field author octo.forge.User
---@field url string
---@field base octo.forge.Branch
---@field head octo.forge.Branch
---@field merge_base string the commit the changes are measured from; base.sha when the forge can't tell

---@class octo.forge.Range
---@field base string commit sha
---@field head string commit sha

---@class octo.forge.ChangedFile
---@field path string
---@field previous_path? string set for renames and copies
---@field status octo.forge.FileStatus
---@field additions integer
---@field deletions integer
---@field patch? string unified diff hunks from the first "@@"; nil for binary or oversized files
---@field viewed? octo.forge.ViewedState nil when the forge doesn't track it, and always for a Range

---@class octo.forge.LineRange
---@field first integer
---@field last integer first <= last

---@class octo.forge.Reaction
---@field content octo.forge.ReactionContent
---@field count integer
---@field viewer_reacted boolean

---@class octo.forge.Comment
---@field id string
---@field author octo.forge.User
---@field body string
---@field created_at string
---@field edited_at? string
---@field url? string
---@field pending boolean part of the viewer's unsubmitted review
---@field viewer_is_author boolean
---@field viewer_can_edit boolean
---@field viewer_can_delete boolean
---@field reactions? octo.forge.Reaction[] nil when the forge has no reactions

---@class octo.forge.Thread
---@field id string
---@field path string
---@field side octo.forge.Side
---@field lines? octo.forge.LineRange position on the current head; nil when outdated or file-level
---@field original_lines? octo.forge.LineRange position on original_commit; nil for file-level threads
---@field original_commit? string the commit the thread was written against; nil when the forge doesn't record it
---@field outdated boolean
---@field resolved boolean
---@field resolved_by? octo.forge.User
---@field diff_hunk? string the hunk around the anchor, for rendering a snippet
---@field comments octo.forge.Comment[] oldest first, never empty

---Where a new thread goes.
---@class octo.forge.Anchor
---@field path string
---@field side octo.forge.Side
---@field lines octo.forge.LineRange
---@field commit? string anchor to the diff this one commit introduced instead of the PR's (feature "commit_comments")

---Exactly one of reply_to and anchor, or neither for a top-level comment.
---@class octo.forge.NewComment
---@field body string
---@field reply_to? string id of the thread to reply to
---@field anchor? octo.forge.Anchor starts a new thread
---@field draft? boolean hold in the viewer's pending review until submit (feature "draft"); not for top-level comments

---@class octo.forge.Posted
---@field comment octo.forge.Comment
---@field thread? octo.forge.Thread the thread now holding the comment; nil for top-level comments

return {}
