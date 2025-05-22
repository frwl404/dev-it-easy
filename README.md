# `rego`: A single-file tool that greatly simplifies the development workflow for any repository.

[![CI](https://github.com/frwl404/dev-it-easy/actions/workflows/ci.yml/badge.svg?event=push)](https://github.com/frwl404/dev-it-easy/actions/workflows/ci.yml)

## 🔍 Problem: nowadays, every repo has its own development workflow
When switching to a new repository, one of the first questions is: *"How do I run build/lint/tests/... here?"*  

Good repositories have documentation, explaining the procedure. 
Ideally, they use **Docker**, so you don’t need to install anything, 
but need to know right commands to start with. 
However, the next repository you work on, will likely have a **different** process - maybe also Docker-based, but still different.  

**The result:**
- Constantly learning/developing different workflows slows you down;
- Workflow, designed from scratch, might be very far from optimal;
- Might be needed to install different SW from repo to repo;
- Too complex/unusual workflow may scare away new contributors.


## ✅ Solution: `rego`
Imagine you could enter **any repo** and immediately know **what** can be done and **how** to do it.  
With `rego`, just run:  
```
> ./rego
Following commands are available:
  * test - runs unit tests (pytest) ['./rego tests --cov -vv', './rego tests --last-failed']
  * build - builds the project ['./rego build']
  * shell - debug container by running shell in interactive mode (keep container running) ['./rego shell']
  * pre-commit - quick checks/fixes of code formatting (ruff/mypy) ['./rego pre-commit']
  * update-deps - updates dependencies, used in project, to the latest versions ['./rego update-deps']
```

You immediately see **WHAT** can be done in this repo and **HOW** it can be done.  
Now, running build is as simple as:
```
> ./rego build
Buld is running
done
```

## 🔀 Cross-Platforming
But what if you want to perform build/tests/... for different platforms? 
Not a problem, just ask `rego` to show all available containers and run
command in any of them as easy as that:
```
> ./rego --containers
Following containers are available:
  * Debian
  * Centos
  * RockyLinux

> ./rego -c Debian build
Buld for Debian is running
done
```

or you can run command in all available containers:
```
> ./rego -c "*" test
Running test for Debian
PASSED
Running test for Centos
PASSED
Running test for RockyLinux
PASSED
```

## 🎯 Why use rego?
- Standardized workflow across different repositories
- Zero installation (just add 1 file to your repo)
- `rego` need only Python and Docker. Both are present almost everywhere nowadays.
- Works across multiple platforms effortlessly

## 🚀 Quick start.

Follow [this short instruction](docs/QUICK_START.md) to integrate rego into your project.  
In case of some problems, please feel free to contact author:
- Email: anton.chivkunov@gmail.com

