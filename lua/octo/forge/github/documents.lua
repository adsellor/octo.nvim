---GraphQL documents used by the GitHub adapter. Self-contained: they ask for exactly the fields
---the adapter maps, and take every value as a variable.
local M = {}

local reactions = [[
  reactionGroups { content viewerHasReacted reactors { totalCount } }
]]

local review_comment = [[
fragment OctoForgeReviewComment on PullRequestReviewComment {
  id body createdAt lastEditedAt url
  author { login }
  viewerDidAuthor viewerCanUpdate viewerCanDelete
  diffHunk
  originalCommit { oid }
  pullRequestReview { state }
]] .. reactions .. [[
}
]]

local thread = [[
fragment OctoForgeThread on PullRequestReviewThread {
  id path diffSide line startLine originalLine originalStartLine isOutdated isResolved
  resolvedBy { login }
  comments(first: 100) { nodes { ...OctoForgeReviewComment } }
}
]] .. review_comment

local issue_comment = [[
fragment OctoForgeIssueComment on IssueComment {
  id body createdAt lastEditedAt url
  author { login }
  viewerDidAuthor viewerCanUpdate viewerCanDelete
]] .. reactions .. [[
}
]]

local review = [[
fragment OctoForgeReview on PullRequestReview {
  id body createdAt lastEditedAt url state
  author { login }
  viewerDidAuthor viewerCanUpdate viewerCanDelete
}
]]

M.pull_request = [[
query OctoForgePullRequest($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id number title body state isDraft url
      author { login }
      baseRefName baseRefOid headRefName headRefOid
      baseRepository { owner { login } name }
      headRepository { owner { login } name }
    }
  }
}
]]

---Open pull requests from a branch, newest first.
---`{github_com}` takes fields that only github.com has, or nothing on GitHub Enterprise Server.
M.pull_requests = [[
query OctoForgePullRequests(
  $owner: String!, $name: String!, $states: [PullRequestState!], $head: String, $base: String,
  $labels: [String!], $orderBy: IssueOrder, $cursor: String
) {
  repository(owner: $owner, name: $name) {
    pullRequests(
      first: 100, after: $cursor, states: $states, headRefName: $head, baseRefName: $base,
      labels: $labels, orderBy: $orderBy
    ) {
      nodes {
        number title body url state isDraft createdAt updatedAt
        author { login }
        baseRefName headRefName
        baseRepository { owner { login } name }
        headRepository { owner { login } name }
        labels(first: 20) { nodes { name } }
        {github_com}
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
]]

M.pull_requests_github_com = "isInMergeQueue stackEntry { position stack { size } }"

M.contents = [[
query OctoForgeContents($owner: String!, $name: String!, $expression: String!) {
  repository(owner: $owner, name: $name) {
    object(expression: $expression) { ... on Blob { text } }
  }
}
]]

---The pull request's node id, head and the viewer's pending review, if any.
M.review_target = [[
query OctoForgeReviewTarget($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id headRefOid
      reviews(states: PENDING, first: 20) { nodes { id viewerDidAuthor } }
    }
  }
}
]]

M.threads = [[
query OctoForgeThreads($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { ...OctoForgeThread }
      }
    }
  }
}
]] .. thread

M.thread = [[
query OctoForgeThread($id: ID!) {
  node(id: $id) { ...OctoForgeThread }
}
]] .. thread

M.viewed_files = [[
query OctoForgeViewedFiles($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      files(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { path viewerViewedState }
      }
    }
  }
}
]]

M.add_review = [[
mutation OctoForgeAddReview($input: AddPullRequestReviewInput!) {
  addPullRequestReview(input: $input) { pullRequestReview { id } }
}
]]

M.submit_review = [[
mutation OctoForgeSubmitReview($input: SubmitPullRequestReviewInput!) {
  submitPullRequestReview(input: $input) { pullRequestReview { id } }
}
]]

M.delete_review = [[
mutation OctoForgeDeleteReview($input: DeletePullRequestReviewInput!) {
  deletePullRequestReview(input: $input) { pullRequestReview { id } }
}
]]

M.add_thread = [[
mutation OctoForgeAddThread($input: AddPullRequestReviewThreadInput!) {
  addPullRequestReviewThread(input: $input) { thread { ...OctoForgeThread } }
}
]] .. thread

M.add_reply = [[
mutation OctoForgeAddReply($input: AddPullRequestReviewThreadReplyInput!) {
  addPullRequestReviewThreadReply(input: $input) { comment { id } }
}
]]

---Position-based comment, the only way to anchor to a single commit's diff.
M.add_commit_comment = [[
mutation OctoForgeAddCommitComment($input: AddPullRequestReviewCommentInput!) {
  addPullRequestReviewComment(input: $input) { comment { id } }
}
]]

M.add_comment = [[
mutation OctoForgeAddComment($input: AddCommentInput!) {
  addComment(input: $input) { commentEdge { node { ...OctoForgeIssueComment } } }
}
]] .. issue_comment

M.update_review_comment = [[
mutation OctoForgeUpdateReviewComment($input: UpdatePullRequestReviewCommentInput!) {
  updatePullRequestReviewComment(input: $input) { pullRequestReviewComment { ...OctoForgeReviewComment } }
}
]] .. review_comment

M.update_issue_comment = [[
mutation OctoForgeUpdateIssueComment($input: UpdateIssueCommentInput!) {
  updateIssueComment(input: $input) { issueComment { ...OctoForgeIssueComment } }
}
]] .. issue_comment

M.update_review = [[
mutation OctoForgeUpdateReview($input: UpdatePullRequestReviewInput!) {
  updatePullRequestReview(input: $input) { pullRequestReview { ...OctoForgeReview } }
}
]] .. review

M.delete_review_comment = [[
mutation OctoForgeDeleteReviewComment($input: DeletePullRequestReviewCommentInput!) {
  deletePullRequestReviewComment(input: $input) { clientMutationId }
}
]]

M.delete_issue_comment = [[
mutation OctoForgeDeleteIssueComment($input: DeleteIssueCommentInput!) {
  deleteIssueComment(input: $input) { clientMutationId }
}
]]

M.resolve_thread = [[
mutation OctoForgeResolveThread($input: ResolveReviewThreadInput!) {
  resolveReviewThread(input: $input) { thread { ...OctoForgeThread } }
}
]] .. thread

M.unresolve_thread = [[
mutation OctoForgeUnresolveThread($input: UnresolveReviewThreadInput!) {
  unresolveReviewThread(input: $input) { thread { ...OctoForgeThread } }
}
]] .. thread

M.add_reaction = [[
mutation OctoForgeAddReaction($input: AddReactionInput!) {
  addReaction(input: $input) {
]] .. reactions .. [[
  }
}
]]

M.remove_reaction = [[
mutation OctoForgeRemoveReaction($input: RemoveReactionInput!) {
  removeReaction(input: $input) {
]] .. reactions .. [[
  }
}
]]

M.mark_viewed = [[
mutation OctoForgeMarkViewed($input: MarkFileAsViewedInput!) {
  markFileAsViewed(input: $input) { clientMutationId }
}
]]

M.unmark_viewed = [[
mutation OctoForgeUnmarkViewed($input: UnmarkFileAsViewedInput!) {
  unmarkFileAsViewed(input: $input) { clientMutationId }
}
]]

return M
