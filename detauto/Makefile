# detauto — deterministic Pascal desktop automation
# Makefile: builds all units + main program
# Requires: Free Pascal Compiler (fpc), libX11 dev headers, libepoll dev

FPC      := fpc
FPDFLAGS := -Mobjfpc -Sh -CX -XX -O2
UNITS    := units
SRCS     := $(UNITS)/detauto_types.pas \
            $(UNITS)/detauto_uinput.pas \
            $(UNITS)/detauto_inputevt.pas \
            $(UNITS)/detauto_x11keys.pas \
            $(UNITS)/detauto_ipc.pas
PROGRAM  := detauto
UNITOUT  := build
OUTDIR   := build

.PHONY: all clean check install

all: $(PROGRAM)

$(PROGRAM): detauto.lpr $(SRCS)
	@mkdir -p $(UNITOUT)
	$(FPC) $(FPDFLAGS) -Fu$(UNITS) -FU$(UNITOUT) -FE$(OUTDIR) detauto.lpr

check: $(PROGRAM)
	@echo "Running unit checks..."
	@for u in $(SRCS); do \
		$(FPC) $(FPDFLAGS) -Fu$(UNITS) -FU$(UNITOUT) -Mobjfpc -Sh -c $$u 2>&1 | \
		grep -i "error\|fatal" && exit 1 || true; \
	done
	@echo "All unit checks passed."

install: $(PROGRAM)
	@mkdir -p /usr/local/bin
	cp $(OUTDIR)/$(PROGRAM) /usr/local/bin/detauto
	@echo "Installed detauto to /usr/local/bin/detauto"

clean:
	rm -rf $(UNITOUT) $(OUTDIR)
