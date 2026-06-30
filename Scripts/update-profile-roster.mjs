#!/usr/bin/env node

import fs from "node:fs";

const START = "<!-- profile-roster:start -->";
const END = "<!-- profile-roster:end -->";

const args = new Map();
for (let index = 2; index < process.argv.length; index += 1) {
  if (process.argv[index].startsWith("--")) {
    args.set(process.argv[index], process.argv[index + 1]);
    index += 1;
  }
}

const repository = args.get("--repo") || process.env.GITHUB_REPOSITORY;
const token = args.get("--token") || process.env.GITHUB_TOKEN;

if (!repository || !repository.includes("/")) {
  console.error("Set GITHUB_REPOSITORY or pass --repo owner/name");
  process.exit(1);
}

const [owner, repo] = repository.split("/", 2);

async function get(path) {
  const headers = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "workshop-wallpaper-bridge-profile-roster",
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const response = await fetch(`https://api.github.com${path}`, { headers });
  if (!response.ok) {
    const error = new Error(`GitHub API ${response.status} for ${path}`);
    error.status = response.status;
    throw error;
  }
  return response.json();
}

async function paginate(path) {
  const items = [];
  let nextPath = path;
  while (nextPath) {
    const data = await get(nextPath);
    if (!Array.isArray(data)) {
      throw new Error(`Expected an array from ${nextPath}`);
    }
    items.push(...data);

    const url = new URL(`https://api.github.com${nextPath}`);
    const perPage = Number(url.searchParams.get("per_page") || "100");
    const page = Number(url.searchParams.get("page") || "1");
    if (data.length < perPage) {
      nextPath = null;
    } else {
      url.searchParams.set("page", String(page + 1));
      nextPath = `${url.pathname}${url.search}`;
    }
  }
  return items;
}

function profileFromUser(raw, contributions = null) {
  if (!raw?.login || !raw?.html_url || !raw?.avatar_url) {
    return null;
  }
  if (raw.login.endsWith("[bot]")) {
    return null;
  }
  return {
    login: raw.login,
    name: raw.name || null,
    htmlUrl: raw.html_url,
    avatarUrl: raw.avatar_url,
    contributions,
  };
}

async function getUser(login, contributions = null) {
  return profileFromUser(await get(`/users/${encodeURIComponent(login)}`), contributions);
}

function dedupeProfiles(profiles) {
  const seen = new Set();
  const result = [];
  for (const profile of profiles) {
    if (!profile) {
      continue;
    }
    const key = profile.login.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(profile);
  }
  return result;
}

async function resolveMaintainers() {
  const maintainers = [];
  try {
    const collaborators = await paginate(
      `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/collaborators?affiliation=direct&per_page=100`,
    );
    for (const collaborator of collaborators) {
      const permissions = collaborator.permissions || {};
      if (permissions.admin === true || permissions.maintain === true || permissions.push === true) {
        maintainers.push(await getUser(collaborator.login));
      }
    }
  } catch (error) {
    if (error.status !== 403 && error.status !== 404) {
      throw error;
    }
    console.error("warning: could not list collaborators; falling back to repository owner");
  }

  if (maintainers.length === 0) {
    maintainers.push(await getUser(owner));
  }
  return dedupeProfiles(maintainers);
}

async function resolveContributors() {
  const contributors = await paginate(
    `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/contributors?anon=false&per_page=100`,
  );
  return dedupeProfiles(
    await Promise.all(
      contributors
        .filter((contributor) => contributor.login && Number.isInteger(contributor.contributions))
        .map((contributor) => getUser(contributor.login, contributor.contributions)),
    ),
  );
}

function display(profile) {
  const label = profile.name || profile.login;
  if (label === profile.login) {
    return `[@${profile.login}](${profile.htmlUrl})`;
  }
  return `[${label}](${profile.htmlUrl}) \`@${profile.login}\``;
}

function avatar(profile) {
  const separator = profile.avatarUrl.includes("?") ? "&" : "?";
  return `<a href="${profile.htmlUrl}"><img src="${profile.avatarUrl}${separator}s=72" width="36" height="36" alt="@${profile.login}"></a>`;
}

function renderSection(maintainers, contributors, korean) {
  const generated = korean
    ? "이 영역은 GitHub 사용자 프로필에서 자동 생성됩니다."
    : "This section is generated from GitHub user profiles.";
  const maintainerHeading = korean ? "메인테이너" : "Maintainers";
  const contributorHeading = korean ? "기여자" : "Contributors";
  const empty = korean ? "아직 GitHub 프로필로 연결된 사용자가 없습니다." : "No linked GitHub profiles yet.";

  const lines = [START, generated, "", `### ${maintainerHeading}`, ""];
  lines.push(...(maintainers.length > 0 ? maintainers.map((profile) => `- ${avatar(profile)} ${display(profile)}`) : [`- ${empty}`]));
  lines.push("", `### ${contributorHeading}`, "");
  if (contributors.length > 0) {
    for (const profile of contributors) {
      lines.push(`- ${avatar(profile)} ${display(profile)}`);
    }
  } else {
    lines.push(`- ${empty}`);
  }
  lines.push(END, "");
  return lines.join("\n");
}

function replaceRoster(path, rendered) {
  const content = fs.readFileSync(path, "utf8");
  if (!content.includes(START) || !content.includes(END)) {
    throw new Error(`${path} must contain ${START} and ${END} markers`);
  }
  const before = content.slice(0, content.indexOf(START)).trimEnd();
  const after = content.slice(content.indexOf(END) + END.length);
  const updated = `${before}\n\n${rendered.trimEnd()}${after}`;
  if (updated === content) {
    return false;
  }
  fs.writeFileSync(path, updated, "utf8");
  return true;
}

const maintainers = await resolveMaintainers();
const contributors = await resolveContributors();
replaceRoster("README.md", renderSection(maintainers, contributors, false));
replaceRoster("README.ko.md", renderSection(maintainers, contributors, true));
