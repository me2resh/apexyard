#!/usr/bin/env bash
# Select questions, show reuse candidates, or derive the summary. No stdin reads.
set -eu
base="$(cd "$(dirname "$0")/.." && pwd)"
scale='' spec='' onboarding='' prd='' shape='' run='' host='' provider='' mode=questions
bad() { printf 'input: %s\n' "$1" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mapped|--derive) mode=${1#--}; shift; continue ;;
  esac
  [ "$#" -ge 2 ] && [ -n "$2" ] || bad 'expected an option value'
  case "$1" in
    --scale) scale=$2 ;; --spec) spec=$2 ;; --onboarding) onboarding=$2 ;;
    --prd-answers) prd=$2 ;; --shape) shape=$2 ;; --run-answers) run=$2 ;;
    --host) host=$2 ;; --host-provider) provider=$2 ;; *) bad "unknown option $1" ;;
  esac
  shift 2
done
case "$scale" in ''|demo|small|production) ;; *) bad 'scale must be demo, small, or production' ;; esac
spec_json='{}' prd_json='{}' onboarding_json='{}' run_json='{}'
read_object() {
  [ -r "$1" ] || bad 'cannot read answers'
  jq -se 'if length == 1 and (.[0]|type) == "object" then .[0] else error("object required") end' "$1" || bad 'invalid answers'
}
if [ -n "$spec" ]; then
  spec_json=$(read_object "$spec")
  # Old specs remain readable so removed fields can appear in the summary.
  [ "$(jq -r '.specVersion' <<< "$spec_json")" = 0.1 ] || bad 'unknown spec version'
fi
[ -z "$prd" ] || prd_json=$(read_object "$prd")
[ -z "$run" ] || run_json=$(read_object "$run")
if [ -n "$onboarding" ]; then
  [ -r "$onboarding" ] || bad 'cannot read onboarding'
  # Read only simple scalar entries in the two named blocks. Never execute YAML.
  block='' entries='{}'
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*(#.*)?$ ]]; then
      block=${BASH_REMATCH[1]}; continue
    fi
    if [[ "$line" =~ ^[^[:space:]#] ]]; then block=''; continue; fi
    case "$block" in onboarding|tech_stack) ;; *) continue ;; esac
    if [[ "$line" =~ ^\ \ ([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
      value=${value%% \#*}
      while [[ "$value" == *' ' ]]; do value=${value% }; done
      if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value=${value:1:${#value}-2}; fi
      case "$value" in ''|null|'~'|'['*|'{'*|'|'*|'>'*) continue ;; esac
      entries=$(jq --arg key "$block.$key" --arg value "$value" '. + {($key):$value}' <<< "$entries")
    fi
  done < "$onboarding"
  onboarding_json=$entries
fi
jq -r --arg mode "$mode" --arg scale "$scale" --arg shape "$shape" --arg host "$host" --arg provider "$provider" \
  --argjson spec "$spec_json" --argjson prd "$prd_json" --argjson onboarding "$onboarding_json" --argjson run "$run_json" \
  --slurpfile rules "$base/rules.json" '
  def record($source): if type == "object" and has("value") then . else {value:.,source:$source} end;
  def cloud: {"AWS":"AWS","GCP":"Google Cloud","Google Cloud":"Google Cloud","Azure":"Azure"}[.];
  def canonical($key):
    if $key == "shape" then
      {"A website or web app":"web app","A service that other software calls":"API service","A scheduled or data job":"data pipeline"}[.] // .
    elif $key == "scale" then
      {"Real users, at small scale":"small","Just me, to try it out":"demo","Paying customers or a business service":"production"}[.] // .
    elif $key == "dataSensitivity" then
      {"Personal details, such as names or emails":"personal","No personal details":"none","Payment details":"payment","no personal data":"none"}[.] // .
    elif $key == "hostKind" then
      {"A hosting service that runs it for you":"hosting service","Your company cloud":"company cloud","A server or container you run":"server or container"}[.] // .
    elif $key == "releaseCheck" then
      {"A teammate approves each live release":"teammate","It goes live after the checks pass":"checks","A named release owner, in a set time window":"window"}[.] // .
    else . end;
  def accepted($key):
    . as $v | ({hostKind:["hosting service","company cloud","server or container","other"],hostProvider:["AWS","Google Cloud","Azure"],shape:["web app","API service","data pipeline","other"],scale:["demo","small","production"],dataSensitivity:["none","personal","payment"],releaseCheck:["teammate","checks","window"],reuseConfirm:["Use these","Change one","Ignore them and ask me"],setupChoice:["Use this setup","Start with a minimal custom setup"]}[$key] // []) as $allowed |
    if $key == "storage" or $key == "hostService" then type == "string" and length > 0 else ($allowed | index($v)) != null end;
  def answers($source):
    with_entries(.key = (if .key == "host" then "hostKind" else .key end) |
      .key as $key | .value |= (record($source) | .value |= canonical($key))) |
    with_entries(.key as $key | select(.value.value | accepted($key))) |
    with_entries(select(.key != "storage" or .value.source != "derived")) |
    with_entries(select(.key != "hostService" or (.value.source == "owner" or .value.source == "onboarding")));
  ($onboarding["onboarding.hosting"] // $onboarding["tech_stack.hosting"] // "") as $hosting |
  ($hosting | cloud) as $hostingCloud |
  ($onboarding["onboarding.cloud"] // $onboarding["tech_stack.cloud"] // "" | cloud) as $cloud |
  (if $hostingCloud != null then {hostKind:{value:"company cloud",source:"onboarding"},hostProvider:{value:$hostingCloud,source:"onboarding"}}
   elif (["Netlify","Vercel","Render","Fly.io","Heroku","Amplify"] | index($hosting)) != null then {hostKind:{value:"hosting service",source:"onboarding"},hostService:{value:$hosting,source:"onboarding"}}
   else {} end) as $hostingAnswers |
  (($cloud | if . == null then {} else {hostProvider:{value:.,source:"onboarding"}} end) + $hostingAnswers +
   ( ($onboarding["onboarding.database"] // $onboarding["tech_stack.database"] // "") |
     if . == "" then {} else {storage:{value:.,source:"onboarding"}} end)) as $onboard |
  ($prd | (.answers // .) | if has("dataSensitivity") then . else if has("data") then . + {dataSensitivity:.data} else . end end | {shape,scale,dataSensitivity} | with_entries(select(.value != null)) | answers("prd")) as $prds |
  ((if $spec.scale == null then {} else {scale:{value:$spec.scale,source:"owner"}} end) + ($spec.answers // {}) | answers("owner")) as $existing |
  ($run | (.answers // .) | answers("owner")) as $runs |
  ($runs + (if $host == "" then {} else {hostKind:{value:$host,source:"owner"}} end) +
    (if $provider == "" then {} else {hostProvider:{value:$provider,source:"owner"}} end) +
    (if $shape == "" then {} else {shape:{value:$shape,source:"owner"}} end)) as $current |
  ($onboard + $prds + $existing + $current |
    if .hostKind != null and .hostKind.value != "hosting service" then del(.hostService) else . end) as $known |
  ($onboard + $prds + $existing | del(.reuseConfirm,.setupChoice) |
    with_entries(.key as $key | .value = $known[$key] | select(.value != null))) as $mapped |
  ($known.reuseConfirm.value == "Use these") as $confirmed |
  (if $confirmed then $known else $current end |
    if .hostKind != null and .hostKind.value != "hosting service" then del(.hostService) else . end) as $applied |
  (if $known.reuseConfirm == null then $known else $applied end) as $questionAnswers |
  ($known.reuseConfirm.value == "Ignore them and ask me") as $ignored_reuse |
  ($current.scale.value // (if $confirmed then $known.scale.value else null end) // (if $scale == "" then "small" else $scale end)) as $tier |
  # "Ignore them and ask me" drops company and PRD values from conflicts too.
  ((if $ignored_reuse then [ {}, {}, {}, $existing, $current ] else [ (if $cloud == null then {} else {hostProvider:{value:$cloud,source:"onboarding"}} end),$onboard,$prds,$existing,$current ] end) | to_entries |
    [ .[] | .key as $rank | .value | to_entries[] | {rank:$rank,key:.key,answer:.value} ] |
    group_by(.key) | map(select((map(.answer.value) | unique | length) > 1) |
      {field:.[0].key,values:map(.answer),selected:$known[.[0].key]}) ) as $conflicts |
  ($spec.answers // {} | keys - ["reuseConfirm","scale","hostKind","hostProvider","hostService","shape","dataSensitivity","storage","releaseCheck","setupChoice"]) as $old |
  ($onboarding | keys - ["onboarding.hosting","onboarding.cloud","onboarding.database","tech_stack.hosting","tech_stack.cloud","tech_stack.database","tech_stack.language","tech_stack.ci_cd"]) as $ignored |
  {language:$onboarding["tech_stack.language"],ciSystem:$onboarding["tech_stack.ci_cd"]} as $notes |
  if $mode == "mapped" then
    {answers:$mapped,conflicts:$conflicts,unusedFields:($old + ($spec.unusedFields // []) | unique),notUsed:($ignored + (if $hosting != "" and ($hostingAnswers | length) == 0 then ["onboarding.hosting"] else [] end)),notes:$notes}
  elif $mode == "questions" then
    (if ($mapped | length) > 0 and $known.reuseConfirm == null then "reuseConfirm" else empty end),
    (["host","hostProvider","shape","scale"] +
      (if $tier == "demo" then [] elif $tier == "small" then ["dataSensitivity"] else ["dataSensitivity","releaseCheck"] end) | .[] |
      . as $id | (if . == "host" then "hostKind" else . end) as $key |
      select($id != "hostProvider" or ($questionAnswers.hostKind.value == "company cloud" and $questionAnswers.hostProvider == null)) |
      select($current[$key] == null) |
      select(($confirmed and $known[$key] != null) | not) | $id)
  else
    # Unconfirmed candidates must not silently become applied defaults.
    ($applied + {scale:($current.scale // (if $confirmed then $known.scale else null end) // {value:$tier,source:"default"})}) as $used |
    ({hostKind:{value:"hosting service",source:"recommendation",reason:"You get a live link, and you have no servers to look after."},shape:{value:"web app",source:"recommendation",reason:"People can use your product in a browser."},dataSensitivity:(if $tier == "demo" then {value:"none",source:"default"} else {value:"personal",source:"recommendation",reason:"Safeguards cost little. A wrong No is the more costly mistake."} end),releaseCheck:{value:(if $tier == "production" then "teammate" else "checks" end),source:"default"},setupChoice:{value:"Use this setup",source:"default"}} + $used) as $a |
    ($a + (if $tier == "demo" then {dataSensitivity:{value:"none",source:"default"},releaseCheck:{value:"checks",source:"default"}} else {} end) + (if $a.hostKind.value == "company cloud" and $a.hostProvider == null then {hostProvider:{value:"AWS",source:"recommendation",reason:"The framework has tested infrastructure files for AWS."}} else {} end)) as $a |
    ($rules[0].rows | to_entries | map(select(
      if $a.setupChoice.value == "Start with a minimal custom setup" then .key == 6
      else .value.match | to_entries | all(.[]; .key as $k | .value | index($a[$k].value) != null) end)) | .[0]) as $row |
    ($row.value.goldenPath | if type == "object" then .[$a.shape.value] else . end) as $path |
    ($a + {storage:($a.storage // {value:(if $a.shape.value == "web app" and $a.dataSensitivity.value == "none" then "none" else "Choose storage before launch." end),source:"derived"})}) as $a |
    {row:($row.key+1),rule:$row.value,goldenPath:$path,sentence:($row.value.sentence | if $a.hostKind.value == "hosting service" then split("Netlify") | join($a.hostService.value // "Netlify") else . end),answers:$a,
     pipeline:$row.value.pipeline,scaleAdditions:$rules[0].scaleAdditions[$tier],dataSensitivityAdditions:$rules[0].dataSensitivityAdditions[$a.dataSensitivity.value],
     manualSteps:(($row.value.manualSteps | map(if $a.hostKind.value == "hosting service" then split("Netlify") | join($a.hostService.value // "Netlify") else . end)) + (if $tier == "production" and $a.releaseCheck.value != "checks" then ["Set the environment reviewer in repo settings (o4)."] else [] end)),
     infraDraft:$row.value.infraDraft,
     defaults:({coverage:{value:80,source:"default"}} + (if $a.shape.value == "web app" then {pageBudgetKB:{value:500,source:"default"}} else {} end) + (if $tier == "demo" then {environments:{value:1,source:"default"},liveOnMerge:{value:"when deploy exists",source:"default"}} else {} end)),
     notes:($notes + {languageClash:($notes.language != null and $notes.language != ({"typescript-nextjs":"TypeScript","python-fastapi":"Python","go-data-pipeline":"Go"}[$path])),ciClash:($notes.ciSystem != null and $notes.ciSystem != "GitHub Actions")}),
     openQuestions:(($spec.openQuestions // []) +
       (if $tier == "demo" and $confirmed and ($prds.dataSensitivity.value == "payment" or $prds.dataSensitivity.value == "personal") then ["The PRD says the product keeps " + $prds.dataSensitivity.value + " details. A demo assumes none. Run /scaffold again at a higher scale before real users."] else [] end) + ($conflicts | map("Conflicting values for " + .field + ": " + (.values | map(.value | tostring) | join(", ")) + ". Selected: " + (.selected.value | tostring) + ". Sources: " + (.values | map(.source) | join(", ")) + ".")) +
       (if $row.key == 6 then ["Choose a host before launch."] elif $row.key == 5 then ["Choose how to deploy before launch."] else [] end) + (if $a.storage.value == "Choose storage before launch." then ["Choose storage before launch."] else [] end)),
     unusedFields:($old + ($spec.unusedFields // []) | unique),notUsed:($ignored + (if $hosting != "" and ($hostingAnswers | length) == 0 then ["onboarding.hosting"] else [] end)),
     notice:"Deploy is not set up yet. This run sets up checks only.",
     releaseNotice:(if $tier == "production" then "Takes effect when deploy is set up." else null end),
     skippedQuestions:(if $tier == "demo" then ["dataSensitivity","releaseCheck"] elif $tier == "small" then ["releaseCheck"] else [] end)}
  end
' "$base/questions.json" || bad 'cannot select or derive setup'
