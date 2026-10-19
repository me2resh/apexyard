#!/bin/bash
# Hermetic AgDR-0253 matrix, fail-before checks and median-of-five timings.
# The payload is data. Never execute an unsafe git command in a fixture.
set -eu
# Keep host session pins and network lookups out of fixtures.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
export ROOT
python3 - "$@" <<'PY'
import collections, json, os, pathlib, re, shutil, signal, statistics, subprocess, sys, tempfile, time
root = pathlib.Path(os.environ['ROOT'])
hooks = root / '.claude/hooks'
mode = sys.argv[1] if len(sys.argv)>1 else 'matrix'
gates = ['block-main-push','validate-branch-name','check-secrets','validate-commit-format','verify-commit-refs','require-agdr-for-arch-changes','block-onboarding-in-git','block-agent-routing-drift']
counts = collections.defaultdict(collections.Counter)
failures = []
with tempfile.TemporaryDirectory(prefix='alias-1748-') as tmp:
    t = pathlib.Path(tmp); home=t/'home'; home.mkdir(); repo=t/'repo'; repo.mkdir(); repo=repo.resolve()
    env = dict(os.environ, HOME=str(home), GIT_CONFIG_GLOBAL=str(home/'config'), GIT_CONFIG_NOSYSTEM='1', LC_ALL='en_US.UTF-8')
    for k in list(env):
        if k.startswith('GIT_CONFIG_') and k not in ('GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM'): del env[k]
    def git(*args):
        return subprocess.run(['git','-C',str(repo),*args],env=env,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True).stdout.strip()
    git('init','-q','-b','feature/GH-1748-test'); git('config','user.name','Test'); git('config','user.email','test@example.invalid')
    git('-c','core.hooksPath=/dev/null','commit','--allow-empty','-qm','fixture')
    # Fail-before base: ALIAS_1748_BASE_HOOKS, else archive a resolved base
    # ref (upstream/dev, origin/dev, then parent of the _lib-git-global.sh
    # change). Skip fail-before when no base ref resolves (CI has no upstream).
    # Perf base: ALIAS_1748_PERF_BASE_HOOKS, else archive 23d8387 (AgDR-0253).
    def ref_ok(ref):
        return subprocess.run(['git','rev-parse','--verify','--quiet',ref+'^{commit}'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    def resolve_failbefore_ref():
        if os.environ.get('ALIAS_1748_BASE_REF'):
            cand=os.environ['ALIAS_1748_BASE_REF']
            return cand if ref_ok(cand) else None
        for cand in ('upstream/dev','origin/dev'):
            if ref_ok(cand):
                return cand
        log=subprocess.run(['git','log','-1','--format=%H','--','.claude/hooks/_lib-git-global.sh'],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        if log.returncode==0 and log.stdout.strip():
            parent=log.stdout.strip()+'^'
            if ref_ok(parent):
                return parent
        return None
    def archive_hooks(ref, label):
        scratch=pathlib.Path(os.environ.get('ALIAS_1748_SCRATCH') or tempfile.mkdtemp(prefix='alias-1748-base-'))
        scratch.mkdir(parents=True, exist_ok=True)
        base=scratch/('hooks-'+label+'-'+re.sub(r'[^A-Za-z0-9._-]+','-',ref))
        base=pathlib.Path(tempfile.mkdtemp(prefix=base.name+'-',dir=scratch))
        archive=subprocess.run(['git','archive',ref,'.claude/hooks'],cwd=root,check=True,stdout=subprocess.PIPE).stdout
        subprocess.run(['tar','-x','-C',str(base)],input=archive,check=True)
        return base/'.claude/hooks'
    if os.environ.get('ALIAS_1748_BASE_HOOKS'):
        basehooks=pathlib.Path(os.environ['ALIAS_1748_BASE_HOOKS'])
    else:
        base_ref=resolve_failbefore_ref()
        if base_ref:
            basehooks=archive_hooks(base_ref, 'failbefore')
        else:
            print('SKIP fail-before: no base ref', flush=True)
            basehooks=None
    if mode.startswith('perf'):
        if os.environ.get('ALIAS_1748_PERF_BASE_HOOKS'):
            basehooks=pathlib.Path(os.environ['ALIAS_1748_PERF_BASE_HOOKS'])
        else:
            basehooks=archive_hooks(os.environ.get('ALIAS_1748_PERF_BASE_REF','23d8387'), 'perf')
    config=home/'config'
    def configure(entries=()):
        config.write_text('')
        for key,val in entries: git('config','--global','--add',key,val)
    def run(hook,cmd,which=None,shell='/bin/bash',extra=None,payloadcwd=None):
        which=which or hooks
        workingcwd=payloadcwd or repo
        payload=json.dumps({'tool_name':'Bash','tool_input':{'command':cmd},'cwd':str(workingcwd)})
        e=env.copy(); e.update(extra or {})
        if hook=='resolver':
            script='source "$1"; cmd="$2"; cwd="$3"; git_alias_check push commit'
            p=subprocess.run(['/bin/bash','-c',script,'probe',str(which/'_lib-git-global.sh'),cmd,str(repo)],env=e,cwd=workingcwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            return p.returncode,p.stdout+p.stderr
        command=['/bin/bash',str(which/(hook+'.sh'))]
        if shell.endswith('zsh'): command=[shell,'-c','exec /bin/bash "$@"','alias-test',str(which/(hook+'.sh'))]
        if mode.startswith('perf'):
            # Relative budget only (AgDR-0253 CEO decision 14). The base
            # dispatcher already exceeds the hook timeout on large inputs
            # (#1777 / #1780). Allow a long wall clock so medians stay valid.
            p=subprocess.Popen(command,stdin=subprocess.PIPE,env=e,cwd=workingcwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            try:
                out,err=p.communicate(payload,timeout=120)
                return p.returncode,out+err
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL)
                out,err=p.communicate()
                return 124,out+err+'\nTIMEOUT: exceeded 120 seconds'
        p=subprocess.run(command,input=payload,env=e,cwd=workingcwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        return p.returncode,p.stdout+p.stderr
    lastgroup=['']
    def case(group,name,cmd,want=2,entries=(),shells=('/bin/bash',),direct=True):
        if mode=='includes' and group!='Includes': return
        if group!=lastgroup[0]:
            print('GROUP',group,dict(counts[lastgroup[0]]),flush=True); lastgroup[0]=group
        configure(entries)
        for shell in shells:
            for hook in (['resolver'] if mode=='quick' else ['dispatch-bash']+(gates if direct else [])):
                # A direct gate checks its own verbs. Use a shell alias to test
                # all gates, or the verb each gate actually owns.
                expected=want
                if name=='push-name-commit' and hook=='validate-branch-name': expected=0
                if group=='Round-1 regressions' and name=='4' and hook in ('dispatch-bash','validate-commit-format'):
                    expected=2
                    counts['Existing compound-commit blocks']['expected']+=1
                actualcmd=cmd
                actualentries=entries
                if hook not in ('resolver','dispatch-bash','block-main-push','validate-branch-name'):
                    actualcmd=cmd.replace('push','commit').replace('Push','Commit')
                    actualentries=[(k.replace('push','commit'),v.replace('push','commit')) for k,v in entries]
                configure(actualentries)
                includefile=t/'alias-include'
                if includefile.exists():
                    real='commit' if hook not in ('resolver','dispatch-bash','block-main-push','validate-branch-name') else 'push'
                    includefile.write_text('[alias]\n zp = '+real+'\n')
                if want==2 and hook=='validate-branch-name' and 'commit' in cmd and 'push' not in cmd: continue
                rc,out=run(hook,actualcmd,shell=shell)
                label=f'{group}/{name}/{pathlib.Path(shell).name}/{hook}'
                counts[group]['pass' if rc==expected else 'fail']+=1
                if rc!=expected:
                    failures.append((label,expected,rc,out[-1000:])); print('FAIL',label,expected,rc,out[-300:],flush=True)
                before,bout=run(hook,actualcmd,basehooks,shell) if mode!='quick' and basehooks else (0,'')
                if mode=='quick' or not basehooks: continue
                # Each blocked test must expose the baseline gap. Existing
                # direct-verb routing can already block outer real verbs.
                if expected==2:
                    counts['fail-before']['gap' if before!=expected else 'already-blocked']+=1
                else: counts['fail-before']['allow-pass' if before==0 else 'allow-fail']+=1
                counts['fail-before '+group]['gap' if expected==2 and before!=2 else 'already-blocked' if expected==2 else 'allow-pass' if before==0 else 'allow-fail']+=1
    both=('/bin/bash',shutil.which('zsh'))
    both=tuple(s for s in both if s)
    if mode in ('messages','matrix'):
        messages=[
            ('alias','git -c alias.p=push p',(), 'git p is an alias for git push. Run git push directly so the gates can check it.'),
            ('shell','git p',[('alias.p','!echo unsafe')], 'git p is a shell alias. Run the alias body directly so the gates can check it.'),
            ('channel','HOME=/tmp git unknown1748',(), 'this command changes git config (HOME) and runs git unknown1748. Run the real verb without the change. If this is prose, write it to a file and pass -F or --body-file.'),
            ('inline','git -c alias.p="$X" p',(), 'git cannot be checked with this -c value. Quote the -c value. Use a literal key and value with no $, backtick or backslash.'),
            ('opaque','git -C $d status',[('alias.p','!echo unsafe')], 'an unquoted expansion, glob or redirection before the git verb can change the command. Quote the value.'),
            ('candidates','; '.join('git word'+str(i) for i in range(4001)),(), 'too many git mentions to check for aliases. Write the prose to a file and pass -F or --body-file.'),
            ('definition','git config alias.p push; git unknown1748',(), 'this command writes git config and runs git unknown1748. Run them as two commands. If this is prose, write it to a file and pass -F or --body-file.'),
            ('include','git unknown1748',[('includeIf.onbranch:new.path',str(t/'absent'))], 'an includeIf entry can change git config during this command. Run git unknown1748 in a separate command.'),
            ('autocorrect','git unknown1748',[('help.autocorrect','true')], 'help.autocorrect is set and git unknown1748 is not a command. Type the full verb.'),
        ]
        for name,cmd,entries,message in messages:
            configure(entries)
            rc,out=run('resolver',cmd)
            ok=rc==2 and 'BLOCKED: '+message in out
            counts['Block messages']['pass' if ok else 'fail']+=1
            if not ok: failures.append((name,2,rc,out))
        configure(); config.write_text('invalid config [')
        rc,out=run('resolver','git unknown1748')
        ok=rc==2 and f'BLOCKED: cannot read git config for {repo}. Fix the config and retry.' in out
        counts['Block messages']['pass' if ok else 'fail']+=1
        if not ok: failures.append(('config message',2,rc,out))
        configure()
        message_targets=[]
        for i in range(9):
            d=t/('message-target'+str(i)); d.mkdir(); message_targets.append(d)
        rc,out=run('resolver','; '.join(f'git -C {d} unknown1748' for d in message_targets))
        ok=rc==2 and 'BLOCKED: too many git targets to check for aliases. Split the command.' in out
        counts['Block messages']['pass' if ok else 'fail']+=1
        if not ok: failures.append(('target message',2,rc,out))
    if mode=='failbefore-extra':
        configure(); config.write_text('invalid config [')
        for hook in ['dispatch-bash',*gates]:
            for cmd,want in [('git status',0),('git unknown1748',2)]:
                rc,out=run(hook,cmd)
                counts['Failures extra']['pass' if rc==want else 'fail']+=1
                if basehooks:
                    before,bout=run(hook,cmd,basehooks)
                    counts['fail-before Failures']['gap' if want==2 and before!=2 else 'already-blocked' if want==2 else 'allow-pass' if before==0 else 'allow-fail']+=1
                if rc!=want: failures.append((hook,want,rc,out))
        configure()
        nojq=t/'nojq-extra'; nojq.mkdir()
        for directory in env['PATH'].split(':'):
            d=pathlib.Path(directory)
            if d.is_absolute() and d.is_dir():
                for f in d.iterdir():
                    dest=nojq/f.name
                    if f.name!='jq' and f.is_file() and os.access(f,os.X_OK) and not dest.exists(): dest.symlink_to(f)
        for cmd,want in [('git -c alias.p=push p',2),('echo alias.x',0)]:
            rc,out=run('dispatch-bash',cmd,extra={'PATH':str(nojq)})
            counts['No jq extra']['pass' if rc==want else 'fail']+=1
            if basehooks:
                before,bout=run('dispatch-bash',cmd,basehooks,extra={'PATH':str(nojq)})
                counts['fail-before No jq']['gap' if want==2 and before!=2 else 'already-blocked' if want==2 else 'allow-pass' if before==0 else 'allow-fail']+=1
            if rc!=want: failures.append(('no jq',want,rc,out))
    if mode=='limits-baseline':
        limit_targets=[]
        for i in range(9):
            d=t/('limit-target'+str(i)); d.mkdir(); limit_targets.append(d)
        case('Limits upstream','nine-targets','; '.join(f'git -C {d} unknown1748' for d in limit_targets))
        case('Limits upstream','4001-candidates','; '.join('git word'+str(i) for i in range(4001)))
    if mode=='channels-case':
        directory=t/'include.path'; directory.mkdir()
        binary=t/'option-bin'; binary.mkdir()
        external=binary/'git-zdirectory1748'; external.write_text('#!/bin/sh\nexit 0\n'); external.chmod(0o755)
        env['PATH']=str(binary)+':'+env['PATH']
        case('Channels option case','directory',f'git -C {directory} zdirectory1748',0)
        case('Channels option case','config','git -c INCLUDE.path=/tmp/config unknown1748')
    if mode=='case-exact':
        case('Case','push-name-commit','git -c alias.push=commit Push')
        for group,c in counts.items(): print(group,dict(c),flush=True)
        for f in failures: print('FAIL',*f,sep=' | ',flush=True)
        sys.exit(bool(failures))
    if mode in ('matrix','quick','round1','includes'):
        # PR #1756 round-1 payloads. These strings are data, never commands.
        regressions=[
            'cd "$(git rev-parse --show-toplevel)" && grep -rn "git hooks" docs/',
            'cd /private/tmp && echo "git gates"',
            'pushd /private/tmp; echo "git gates"; popd',
            "git commit -F - <<'MSG'\ndocs: explain cd and git hooks\nMSG",
            "git commit -m \"$(cat <<'MSG'\nfix: run cd before the git hooks\nMSG\n)\""
        ]
        for n,cmd in enumerate(regressions):
            case('Round-1 regressions',str(n+1),cmd,0)
        # The original review isolated unrelated gates. Use its same method
        # to prove zero alias blocks for these five exact payloads.
        isolated=t/'isolated-dispatch'; shutil.copytree(hooks,isolated)
        directories=[isolated]
        if basehooks:
            isolatedbase=t/'isolated-base'; shutil.copytree(basehooks,isolatedbase)
            directories=[isolatedbase,isolated]
        for directory in directories:
            for scriptfile in directory.glob('*.sh'):
                if scriptfile.name=='dispatch-bash.sh' or scriptfile.name.startswith('_lib-'): continue
                scriptfile.write_text('#!/bin/bash\ncat >/dev/null\nexit 0\n'); scriptfile.chmod(0o755)
        configure()
        for n,cmd in enumerate(regressions,1):
            for directory in directories:
                rc,out=run('dispatch-bash',cmd,directory)
                counts['Round-1 isolated alias layer']['pass' if rc==0 else 'fail']+=1
                if rc: failures.append(('isolated regression '+str(n),0,rc,out))
        if mode=='round1':
            for group,c in counts.items(): print(group,dict(c),flush=True)
            for f in failures: print('FAIL',*f,sep=' | ',flush=True)
            sys.exit(bool(failures))
        for key,verb in [('ALIAS.x','x'),('alias.X','x'),('alias.x','X'),('alias.Zq.command','Zq'),('alias.push','Push')]:
            case('Case',key+verb,f'git -c {key}=push {verb}')
        case('Case','push-name-commit','git -c alias.push=commit Push')
        case('Case','exact-subsection','git zq',0,[('alias.Zq.command','push')])
        expansions=['-c a.b=c push','-p push','"pu""sh"',r'pu\sh','pu$h','pu`x`sh','-c alias.qq=push qq','--no-pager push','-C /tmp push']
        expansions += ['-c '+k+'=value push' for k in ['core.pager','core.hooksPath','core.fsmonitor','core.editor','sequence.editor','core.sshCommand','diff.external','gpg.program','credential.helper']]
        for value in expansions: case('Expansion',value,'git zz',entries=[('alias.zz',value)],shells=both)
        for boundary in ['', ' ', '\t','\n','(',')','<','>','`','"',"'",';','|','&','=']:
            case('Inner candidates',repr(boundary),boundary+'git zp',entries=[('alias.zp','push')])
        for cmd in ['git -C "$(git zp)" status','git -c x.y="$(git zp)" status','git -C "`git zp`" status','git -c x.y="`git zp`" status']:
            case('Inner candidates',cmd,cmd,entries=[('alias.zp','push')])
        case('Case','quote-concatenation','git z"p"',entries=[('alias.zp','push')])
        case('Case','other-slot','git -c alias.p=status p',entries=[('alias.p.command','!echo unsafe')])
        for key,verb,want in [('alias.P.x' ,'p.x',2),('alias.P.x','P.x',2),('alias.p.X','p.x',2),('alias.P.command','P',2),('alias.P.command','p',0),('alias.p.COMMAND','p',2)]:
            case('Dotted names',key+verb,'git '+verb,want,[(key,'push')])
        for cmd in ['git -c x.y={a,b} status','git {sta,tus}','git -c x.y=z >out status','git>out status','git<in status','git -c x.y=a* status']:
            (repo/'abc').touch()
            case('Shell words',cmd,cmd,entries=[('alias.zp','!echo unsafe')],shells=both)
        for depth in (10,11):
            entries=[('alias.a'+str(i),'a'+str(i+1)) for i in range(depth-1)]+[('alias.a'+str(depth-1),'status')]
            case('Chain','depth'+str(depth),'git a0',0 if depth==10 else 2,entries)
        case('Chain','loop','git aa',entries=[('alias.aa','bb'),('alias.bb','aa')])
        case('Chain','unknown-hop','git aa',0,[('alias.aa','unknown1748')])
        case('Chain','inline-write','git config alias.zz push && git -c alias.p=zz p')
        case('Chain','global-write','git config alias.zz push && git p',entries=[('alias.p','zz')])
        bindir=t/'bin'; bindir.mkdir(); external=bindir/'git-zz'; external.write_text('#!/bin/sh\nexit 0\n'); external.chmod(0o755)
        env['PATH']=str(bindir)+':'+env['PATH']
        case('Lookup order','external','git zz',0)
        for prefix in ['', 'env -u PATH ', 'env -i ', 'unset PATH; ', 'exec -c ', 'PATH= ', 'HOME=/tmp/h ']:
            case('Lookup order',prefix,prefix+'git zz',entries=[('alias.zz','push')])
        case('Lookup order','external-channel','HOME=/tmp/h git zz')
        env['PATH']=env['PATH'].split(':',1)[1]+':../bin'
        case('Lookup order','relative','git zz',entries=[('help.autocorrect','true')])
        tokens=['HOME','XDG_CONFIG_HOME','GIT_DIR','GIT_COMMON_DIR','GIT_CONFIG','GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0','GIT_CONFIG_PARAMETERS','GIT_CONFIG_GLOBAL','GIT_CONFIG_SYSTEM','--config-env=alias.x=V','-c include.path=/tmp/f','-c includeIf.x.path=/tmp/f']
        for token in tokens:
            for form in [token+'=x ', 'export '+token+'; ', 'env '+token+'=x ', 'read -r '+token+'; ', 'echo '+token+'; ']:
                case('Channels',form,form+'git unknown1748')
        for token in ['$HOME','${HOME}']: case('Channels','read'+token,'echo '+token+'; git unknown1748',0)
        for cmd in [r'git -c ali\as.qf=push qf',r'git -c alias.qg=pu\sh qg','git -c alias.qh="$(echo push)" qh',"git -c \"$(printf 'alia%s.qz=push' s)\" qz",'K=ali; git -c "${K}as.qy=push" qy']:
            case('Unreadable inline config',cmd,cmd)
        for cmd in ["X='alias.p=push p'; git -c $X status", "git -c $(printf 'alias.p=push p') status", "X='user.name=me p'; git -c $X status"]:
            case('Opaque verb',cmd,cmd,entries=[('alias.p','push')],shells=both)
        for cmd in ['git -c "$X" status',r'git -c user.name=A\ B status']:
            case('Opaque verb',cmd,cmd,0,shells=both)
        case('Opaque verb','escaped-unknown',r'git -c user.name=A\ B hooks',shells=both)
        case('Opaque verb','C-variable','git -C $d status',entries=[('alias.zz','!echo x')],shells=both)
        inc=t/'alias-include'; inc.write_text('[alias]\n zp = push\n')
        case('Includes','path','git zp',entries=[('include.path',str(inc))])
        case('Includes','gitdir',f'git -C "{repo}" zp',entries=[('includeIf.gitdir:'+str(repo)+'/.path',str(inc))])
        for condition,prefix in [('onbranch:new','git checkout -b new; '),('hasconfig:remote.*.url:https://example.invalid/*','git remote add o https://example.invalid/x; '),('gitdir:'+str(t/'new')+'/',f'git init {t}/new; ')]:
            entries=[('includeIf.'+condition+'.path',str(inc))]
            case('Includes',condition,prefix+'git unknown1748',entries=entries)
            case('Chain',condition,prefix+'git aa',entries=entries+[('alias.aa','unknown1748')])
        case('Includes','basename',f'echo x > {inc}; git unknown1748',entries=[('include.path',str(inc))])
        # Review regressions: equal candidate text must retain each target.
        other=t/'other'; other.mkdir()
        subprocess.run(['git','init','-q',str(other)],env=env,check=True)
        git('config','alias.zp','status')
        subprocess.run(['git','-C',str(other),'config','alias.zp','!echo unsafe'],env=env,check=True)
        case('Target contexts','same-text',f'git zp; cd "{other}"; git zp')
        git('config','--unset','alias.zp')
        # Length framing keeps a pipe in either tuple member unambiguous.
        left=t/'a|b'; right=t/'a'; left.mkdir(); right.mkdir()
        for directory,value in [(left/'c','status'),(right/'b|c','!echo unsafe')]:
            subprocess.run(['git','init','--bare','-q',str(directory)],env=env,check=True)
            subprocess.run(['git','--git-dir='+str(directory),'config','alias.zp',value],env=env,check=True)
        case('Target contexts','tuple-key',f"git -C '{left}' --git-dir=c zp; git -C '{right}' --git-dir='b|c' zp")
        new=t/'new-target'; new.mkdir()
        case('Includes','options-before-init',f'git -C "{new}" init; git -C "{new}" zp',entries=[('includeIf.gitdir/i:'+str(new.resolve())+'/.path',str(inc))])
        case('Includes','quoted-init',f'git -C "{new}" i"nit"; git -C "{new}" zp',entries=[('includeIf.gitdir:'+str(new.resolve())+'/.path',str(inc))])
        # Limits count distinct candidates. Long candidates are opaque.
        case('Limits','duplicate-mentions','; '.join(['git unknown1748']*4001),0)
        case('Limits','long-value','git -c x.y="'+'x'*20000+'" status',0)
        case('Limits','long-verb','git '+'x'*20000,entries=[('alias.zp','!echo unsafe')])
        for val in ['true','1','-1','immediate','prompt','0','false','never','show']:
            case('Unknown verb',val,'git unknown1748',0 if val in ['0','false','never','show'] else 2,[('help.autocorrect',val)])
        case('Unknown verb','write','git config alias.p push && git p')
        case('Failures','lfs','git lfs ls-files',0)
        configure(); config.write_text('invalid config [')
        for cmd,want in [('git status',0),('git unknown1748',2)]:
            for hook in ['dispatch-bash',*gates]:
                rc,out=run(hook,cmd); counts['Failures']['pass' if rc==want else 'fail']+=1
                if rc!=want: failures.append(('bad config '+hook,want,rc,out))
        configure()
        # Fault injection keeps the real resolver and replaces only its fork.
        lib=str(hooks/'_lib-git-global.sh')
        for name,override,cmd,want in [
            ('join','join_shell_continuations() { return 1; }','git unknown1748',2),
            ('grep','grep() { return 2; }','git unknown1748',2),
            ('exec-path','git() { [ "$1" != --exec-path ] || return 1; command git "$@"; }','git unknown1748',0),
            ('list-cmds','git() { [ "$1" != --list-cmds=builtins ] || return 1; command git "$@"; }','git unknown1748',0),
            ('binary','','echo \x01; git -c alias.p=push p',2)]:
            script='source "$1"; source "$(dirname "$1")/_lib-awk-fallback.sh"; '+override+'; cmd="$2"; cwd="$3"; git_alias_check push commit'
            p=subprocess.run(['/bin/bash','-c',script,'probe',lib,cmd,str(repo)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            counts['Internal failures']['pass' if p.returncode==want else 'fail']+=1
            if p.returncode!=want: failures.append((name,want,p.returncode,p.stderr.decode()))
        # All fast-path entries must exist on this host's git.
        fast='add branch checkout cherry-pick clone commit config diff fetch init log ls-files merge mv pull push rebase remote reset rev-parse rm show stash status tag worktree'.split()
        builtins=git('--list-cmds=builtins').split(); ep=pathlib.Path(git('--exec-path'))
        for verb in fast:
            ok=verb in builtins or (ep/('git-'+verb)).is_file(); counts['Fast-path assertions']['pass' if ok else 'fail']+=1
        configure()
        forklog=t/'git-forks'
        # Build the verb list as data, outside the function wrapper's argv.
        script='source "$1"; log="$3"; git() { printf "fork\\n" >> "$log"; command git "$@"; }; cwd="$2"; shift 3; for verb in "$@"; do cmd="git $verb"; git_alias_check push commit || exit 2; done'
        p=subprocess.run(['/bin/bash','-c',script,'forks',lib,str(repo),str(forklog),*fast],env=env,capture_output=True)
        ok=p.returncode==0 and not forklog.exists()
        counts['Fast-path forks']['pass' if ok else 'fail']+=1
        if not ok: failures.append(('Fast-path forks',0,p.returncode,p.stderr.decode()))
        # Canonical key spelling from git must match our two-slot merge.
        for key in ['ALIAS.x','alias.X','alias.P.x','alias.P.command','alias.p.COMMAND']:
            output=git('-c',key+'=push','config','--get-regexp','^alias\\.')
            script='source "$1"; _GA_KEYS=(); _GA_VALUES=(); _git_alias_entry "$2" push; printf "%s" "${_GA_KEYS[*]}"'
            def slot(k): return subprocess.check_output(['/bin/bash','-c',script,'slot',lib,k],env=env,text=True)
            ok=slot(key)==slot(output.split()[0]); counts['Canonical keys']['pass' if ok else 'fail']+=1
        # No jq: keep every other executable, even on hosts with several jqs.
        nojq=t/'nojq'; nojq.mkdir()
        for directory in env['PATH'].split(':'):
            d=pathlib.Path(directory)
            if d.is_absolute() and d.is_dir():
                for f in d.iterdir():
                    dest=nojq/f.name
                    if f.name!='jq' and f.is_file() and os.access(f,os.X_OK) and not dest.exists(): dest.symlink_to(f)
        for cmd,want in [('git -c alias.p=push p',2),('echo alias.x',0)]:
            rc,out=run('dispatch-bash',cmd,extra={'PATH':str(nojq)})
            counts['No jq']['pass' if rc==want else 'fail']+=1
            if rc!=want: failures.append(('No jq '+cmd,want,rc,out))
    elif mode.startswith('perf'):
        configure()
        targets=[]
        for i in range(9):
            d=t/('target'+str(i)); d.mkdir(); targets.append(d)
        # Prose payloads use a non-repository cwd. This isolates the alias
        # budget from the unrelated ticket gate's per-command repo probes.
        prose=t/'prose'; prose.mkdir()
        long='x'*20000
        payloads=["cat <<'DOC'\n"+'\n'.join('git word'+str(i) for i in range(40))+"\nDOC", "cat <<'DOC'\n"+'\n'.join(' '.join('git word'+str(i*3+j) for j in range(3)) for i in range(200))+"\nDOC", "git commit -m \"$(cat <<'DOC'\n"+'\n'.join('git word'+str(i) for i in range(40))+"\nDOC\n)\"", '; '.join(f'git -C {d} unknown1748' for d in targets[:8]), '; '.join(f'git -C {d} unknown1748' for d in targets), 'git -c x.y="'+long+'" status', 'git '+long, '; '.join('git word'+str(i) for i in range(2000)), '; '.join('git word'+str(i) for i in range(4001))]
        selected=set(map(int,sys.argv[2].split(','))) if len(sys.argv)>2 else set(range(1,10))
        for n,cmd in enumerate(payloads,1):
            if n not in selected: continue
            for hook in ['dispatch-bash',*gates]:
                times=[]; results=[]
                for source in [basehooks,hooks]:
                    samples=[]
                    for _ in range(5):
                        start=time.perf_counter(); rc,out=run(hook,cmd,source,payloadcwd=repo if n==3 else prose); samples.append(time.perf_counter()-start)
                    times.append(statistics.median(samples)); results.append((rc,out))
                budget=.5 if hook=='dispatch-bash' else .2
                # Relative only: new <= base + budget. No absolute 5 s cap.
                ok=times[1]<=times[0]+budget and results[0][0]!=124 and results[1][0]!=124
                note=''
                if n in (5,9):
                    phrase='too many git targets' if n==5 else 'too many git mentions'
                    ok=ok and results[1][0]==2 and phrase in results[1][1]
                    counts['Perf fail-before']['timeout' if results[0][0]==124 else 'gap' if results[0][0]!=2 else 'already-blocked']+=1
                counts['Perf']['pass' if ok else 'fail']+=1
                timeout_note=' TIMEOUT' if any(r[0]==124 for r in results) else ''
                print(f'PERF {n} {hook} base={times[0]:.4f}s new={times[1]:.4f}s delta={times[1]-times[0]:.4f}s '+('PASS' if ok else 'FAIL')+timeout_note+note,flush=True)
    if mode in ('faults','matrix'):
        originalhooks=hooks
        faultbin=t/'faultbin'; faultbin.mkdir()
        tool=faultbin/'git-zfault1748'; tool.write_text('#!/bin/sh\nexit 0\n'); tool.chmod(0o755)
        faults=[
            ('join','join_shell_continuations() { return 1; }','git unknown1748',2,()),
            ('grep','grep() { case "$*" in *-aboE*) return 2 ;; esac; command grep "$@"; }','git unknown1748',2,()),
            ('exec-path','git() { [ "$1" != --exec-path ] || return 1; command git "$@"; }','git zfault1748',2,[('help.autocorrect','true')]),
            ('list-cmds','git() { [ "$1" != --list-cmds=builtins ] || return 1; command git "$@"; }','git unknown1748',0,()),
            ('binary','','echo \x01; git -c alias.p=push p',2,())]
        for name,override,cmd,want,entries in faults:
            fixture=t/('fault-'+name); shutil.copytree(originalhooks,fixture)
            library=fixture/'_lib-git-global.sh'
            library.write_text(library.read_text()+'\n'+override+'\ntrue\n')
            hooks=fixture
            if name=='exec-path': env['GIT_EXEC_PATH']=str(faultbin)
            case('Internal failures through gates',name,cmd,want,entries)
            env.pop('GIT_EXEC_PATH',None)
        hooks=originalhooks
    if mode in ('fallback','matrix'):
        configure()
        fallback=t/'fallback-dispatch'; shutil.copytree(hooks,fallback)
        for scriptfile in fallback.glob('*.sh'):
            if scriptfile.name=='dispatch-bash.sh' or scriptfile.name.startswith('_lib-'): continue
            scriptfile.write_text('#!/bin/bash\ncat >/dev/null\nexit 0\n'); scriptfile.chmod(0o755)
        library=fallback/'_lib-git-global.sh'; original=library.read_text()
        for broken in ('missing','source-failure'):
            if broken=='missing': library.unlink()
            else: library.write_text(original+'\nfalse\n')
            for cmd,want in [('git -c alias.p=push p',2),('git\n-c ALIAS.p=push p',2),('GIT --CONFIG-ENV=alias.p=V p',2),('echo alias.x',0),('git unknown1748',0)]:
                rc,out=run('dispatch-bash',cmd,fallback)
                counts['Library fallback']['pass' if rc==want else 'fail']+=1
                if rc!=want: failures.append((broken+' '+cmd,want,rc,out))
    for group,c in counts.items(): print(group,dict(c),flush=True)
    for f in failures: print('FAIL',*f,sep=' | ',flush=True)
    print('TOTAL',sum(c['pass'] for c in counts.values()),'passed;',sum(c['fail'] for c in counts.values()),'failed',flush=True)
    sys.exit(bool(failures) or any(c['fail'] for c in counts.values()))
PY
