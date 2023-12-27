https://fitzcarraldoblog.wordpress.com/2020/03/07/my-%EF%BB%BFsystem-upgrade-procedure-for-gentoo-linux/

1. Update the ebuilds on the machine (see Gentoo Wiki – Project:Portage/Sync)

root # emaint sync -a

If I were using the deprecated Portage sync method I would instead have used the following commands:

root # emerge --sync # Update the ebuilds from the main Portage tree

root # layman -S # Update the ebuilds from 3rd-party overlays

2. Upgrade the Portage package manager if the console output from Step 1 included a message telling me to upgrade portage

root # emerge -1v portage

3. As I use the eix and the mlocate utilities, update their data files

root # eix-update && updatedb

4. Check if there are any News items I have not read yet

root # eselect news list

5. Read new News items and make necessary changes, if any

root # eselect news read <n>

6. Perform a dry run for the upgrade of any packages in the World file that have new versions

root # emerge -uvpDN --with-bdeps=y @world

7. If no problems were flagged in Step 6, go to Step 9

8. Sort out any problem(s) flagged in Step 6 then go back to Step 6

9. Launch the upgrade of those packages in the World file that have new versions

root # emerge -uvDN --with-bdeps=y --keep-going @world

My decision on whether or not to include the option ‘--keep-going‘ will depend on the precise circumstances.

10. If Step 9 ran to completion successfully, go to Step 14

11. If Step 9 did not run to completion successfully and it appears the package that failed to merge will not cause further problems, go to Step 12, otherwise fix the problem(s)* and go back to Step 9

*Sometimes I find that one or more packages do not merge successfully during Step 9 but do merge successfully simply by repeating Step 9.

12. Resume the upgrade process

root # emerge --resume --skipfirst

13. If Step 12 did not run to completion successfully and it appears the package that failed to merge will not cause further problems, go back to Step 12, otherwise fix the problem(s) and go back to Step 9

14. Upgrade any packages that are still built against old versions of libraries if the console output from Step 9 or Step 12 includes a message telling me to do that

root # emerge @preserved-rebuild

15. If any problems remain, fix them and go back to Step 14

16. Scan libraries and binaries for missing shared library dependencies and re-merge any broken binaries and shared libraries

root # revdep-rebuild -i

Actually, I cannot recall the last time ‘revdep-rebuild‘ was needed, as Portage has improved so much over the years.

17. Remove outdated and unneeded packages

root # emerge --ask --depclean

18. Merge any configuration files

root # etc-update

I always check the differences between the listed existing and new configuration files before going ahead, and may edit the new configuration file if I deem it necessary.

19. As I use the mlocate utility I make sure its index file is bang up to date

root # updatedb

20. Optionally, I clear out any old source-code and binary packages

root # eclean-dist --deep

21. If I remember to do it, I check if there are any installed obsolete packages and then remove them

root # eix-test-obsolete

22. I make sure no temporary work files have been left around by any failed merges

root # rm -rf /usr/tmp/portage/*

Actually, I created a script in directory /etc/local.d/ to do this automatically when HDD free space gets low (see my blog post ‘Automatically clearing the /usr/tmp/portage directory in Gentoo Linux‘).
